# lib/tasks/image_optimizer.rake (replace the optimize/stats tasks with this)
require "yaml"
require "digest"
require "image_optim"
require "fileutils"
require "etc"

def norm_ext(path)
  ext = File.extname(path).downcase.delete_prefix(".")
  return "jpg" if %w[jpg jpeg].include?(ext)
  ext
end

def human_bytes(n)
  units = %w[B KB MB GB]
  i = 0
  n = n.to_f
  while n >= 1024 && i < units.size - 1
    n /= 1024.0
    i += 1
  end
  format(i.zero? ? "%d %s" : "%.2f %s", (i.zero? ? n.to_i : n), units[i])
end

def image_optim_options_with_autodisable
  bins = {
    pngcrush:   %w[pngcrush],
    advpng:     %w[advpng],
    optipng:    %w[optipng],
    pngquant:   %w[pngquant],
    oxipng:     %w[oxipng],
    jhead:      %w[jhead],
    jpegoptim:  %w[jpegoptim],
    jpegtran:   %w[jpegtran],
    gifsicle:   %w[gifsicle],
    svgo:       %w[svgo ./node_modules/.bin/svgo]
  }
  missing = {}
  bins.each do |worker, names|
    found = names.any? { |n| system("which #{n} >/dev/null 2>&1") }
    missing[worker] = false unless found # false disables worker
  end
  missing[:pngout] = false
  { nice: 10, threads: Etc.nprocessors }.merge(missing)
end

namespace :images do
  desc "Optimize new/changed images; thresholded; track bytes saved; per-type reporting"
  task optimize: :environment do
    manifest_path = Rails.root.join("config/image_optimization_manifest.yml")
    manifest = File.exist?(manifest_path) ? (YAML.load_file(manifest_path) || {}) : {}
    manifest["files"] ||= {}
    manifest["total_bytes_saved"] ||= 0

    threshold_ratio = 0.02 # 2%
    options = image_optim_options_with_autodisable.merge(
      jpegoptim: { allow_lossy: true, max_quality: 85 },
      pngquant:  { quality: 65..85, speed: 1 }
    )

    image_optim = ImageOptim.new(options)

    worker_keys = %i[pngcrush advpng optipng pngquant oxipng jhead jpegoptim jpegtran gifsicle svgo]
    enabled = worker_keys.select { |w| options[w] != false }
    puts "🧰 Enabled workers: #{enabled.map(&:to_s).sort.join(', ')}"

    image_dir = Rails.root.join("app/assets/images")

    # tallies for reporting
    per_type = Hash.new { |h, k| h[k] = { optimized: { count: 0, bytes: 0 }, negligible: { count: 0, bytes: 0 } } }
    session_saved = 0
    optimized_files = []
    negligible_files = []

    Dir.glob("#{image_dir}/**/*.{png,jpg,jpeg,webp,gif,svg}").sort.each do |file|
      before_hash = Digest::SHA256.hexdigest(File.read(file))
      entry = manifest["files"][file] || {}
      next if entry["hash"] == before_hash

      t = norm_ext(file)
      before_size = File.size(file)
      puts "🔍 Checking #{file} (#{before_size} bytes)…"

      image_optim.optimize_image!(file) # in-place when beneficial

      after_size  = File.size(file)
      after_hash  = Digest::SHA256.hexdigest(File.read(file))
      saved       = [before_size - after_size, 0].max
      ratio       = before_size.zero? ? 0.0 : saved.to_f / before_size

      if ratio >= threshold_ratio
        entry["status"]       = "optimized"
        entry["bytes_saved"]  = (entry["bytes_saved"] || 0) + saved
        manifest["total_bytes_saved"] += saved
        session_saved += saved
        per_type[t][:optimized][:count] += 1
        per_type[t][:optimized][:bytes] += saved
        optimized_files << [file, saved]
      else
        entry["status"]       = "negligible"
        entry["bytes_saved"]  ||= 0
        per_type[t][:negligible][:count] += 1
        per_type[t][:negligible][:bytes] += saved
        negligible_files << [file, saved]
      end

      entry["hash"] = after_hash
      entry["size"] = after_size
      manifest["files"][file] = entry
    end

    FileUtils.mkdir_p(File.dirname(manifest_path))
    File.write(manifest_path, manifest.to_yaml)

    # -------- Pretty reporting --------
    puts "\n📦 Optimized (≥ #{(threshold_ratio * 100).to_i}%) — by type"
    %w[jpg png gif svg webp].each do |kind|
      next unless per_type.key?(kind)
      c = per_type[kind][:optimized][:count]
      b = per_type[kind][:optimized][:bytes]
      next if c.zero?
      puts "  • #{kind.upcase}: #{c} file(s), saved #{human_bytes(b)} (avg #{human_bytes((b / c.to_f).round)})"
    end
    if optimized_files.any?
      puts "    Files:"
      optimized_files.first(15).each { |path, saved| puts "      - #{path}  −#{human_bytes(saved)}" }
      puts "      … (#{optimized_files.size - 15} more)" if optimized_files.size > 15
    end

    puts "\n🪶 Negligible (< #{(threshold_ratio * 100).to_i}%) — by type"
    any_negl = false
    %w[jpg png gif svg webp].each do |kind|
      next unless per_type.key?(kind)
      c = per_type[kind][:negligible][:count]
      b = per_type[kind][:negligible][:bytes]
      next if c.zero?
      any_negl = true
      puts "  • #{kind.upcase}: #{c} file(s), net change #{human_bytes(b)}"
    end
    puts "  • none" unless any_negl
    if negligible_files.any?
      puts "    Sample:"
      negligible_files.first(10).each { |path, saved| puts "      - #{path}  (#{saved.zero? ? '0 bytes' : "−#{human_bytes(saved)}"})" }
    end

    puts "\n💾 Saved this run: #{human_bytes(session_saved)}"
    puts "🧮 Total saved (all time): #{human_bytes(manifest['total_bytes_saved'])}"
    puts "✅ Optimization complete."
  end

  desc "Show image optimization stats from manifest (totals by type/status)"
  task stats: :environment do
    manifest_path = Rails.root.join("config/image_optimization_manifest.yml")
    unless File.exist?(manifest_path)
      puts "ℹ️ No manifest at #{manifest_path}"
      next
    end
    manifest = YAML.load_file(manifest_path) || {}
    files = manifest.dig("files") || {}
    per_type = Hash.new { |h, k| h[k] = { optimized: { count: 0, bytes: 0 }, negligible: { count: 0, bytes: 0 } } }

    files.each do |path, meta|
      t = norm_ext(path)
      status = (meta["status"] || "optimized").to_sym
      per_type[t][status][:count] += 1
      per_type[t][status][:bytes] += (meta["bytes_saved"] || 0) if status == :optimized
    end

    total_saved = manifest["total_bytes_saved"] || 0
    total_files = files.size

    puts "🧮 Total bytes saved (all time): #{human_bytes(total_saved)}"
    puts "📂 Tracked files: #{total_files}"
    puts "\nBy type:"
    %w[jpg png gif svg webp].each do |kind|
      next unless per_type.key?(kind)
      opt_c = per_type[kind][:optimized][:count]
      opt_b = per_type[kind][:optimized][:bytes]
      neg_c = per_type[kind][:negligible][:count]
      next if opt_c.zero? && neg_c.zero?
      line = "  • #{kind.upcase}: optimized #{opt_c} (#{human_bytes(opt_b)})"
      line += ", negligible #{neg_c}" if neg_c.positive?
      puts line
    end
  end
end