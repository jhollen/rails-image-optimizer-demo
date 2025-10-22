require "yaml"
require "digest"
require "image_optim"
require "fileutils"
require "etc"

def image_optim_options_with_autodisable
  bins = {
    pngcrush:   %w[pngcrush],
    advpng:     %w[advpng],
    optipng:    %w[optipng],
    pngquant:   %w[pngquant],
    oxipng:     %w[oxipng],
    jhead:      %w[jhead],
    jpegoptim:  %w[jpegoptim],
    jpegtran:   %w[jpegtran], # from jpeg-turbo
    gifsicle:   %w[gifsicle],
    svgo:       %w[svgo ./node_modules/.bin/svgo]
  }

  missing = {}
  bins.each do |worker, names|
    found = names.any? { |n| system("which #{n} >/dev/null 2>&1") }
    missing[worker] = false unless found # false disables worker
  end

  # pngout is nonfree—always disabled
  missing[:pngout] = false

  {
    nice: 10,
    threads: Etc.nprocessors
  }.merge(missing)
end

namespace :images do
  desc "Optimize new/changed images; thresholded; track bytes saved"
  task optimize: :environment do
    manifest_path = Rails.root.join("config/image_optimization_manifest.yml")
    manifest = File.exist?(manifest_path) ? (YAML.load_file(manifest_path) || {}) : {}
    manifest["files"] ||= {}
    manifest["total_bytes_saved"] ||= 0

    threshold_ratio = 0.02 # 2% threshold
    options = image_optim_options_with_autodisable.merge(
      # Mild lossy defaults to ensure demo savings for JPEG/PNG
      jpegoptim: { allow_lossy: true, max_quality: 85 },
      pngquant:  { quality: 65..85, speed: 1 }
    )

    image_optim = ImageOptim.new(options)
    enabled = image_optim.workers.map { |w| w.class.name.split("::").last }.sort
    puts "🧰 Enabled workers: #{enabled.join(', ')}"

    image_dir = Rails.root.join("app/assets/images")
    changed = []
    negligible = []
    session_saved = 0

    Dir.glob("#{image_dir}/**/*.{png,jpg,jpeg,webp,gif,svg}").sort.each do |file|
      before_hash = Digest::SHA256.hexdigest(File.read(file))
      entry = manifest["files"][file] || {}
      next if entry["hash"] == before_hash

      before_size = File.size(file)
      puts "🔍 Checking #{file} (#{before_size} bytes)…"
      image_optim.optimize_image!(file) # in-place when beneficial

      after_size  = File.size(file)
      after_hash  = Digest::SHA256.hexdigest(File.read(file))
      saved       = [before_size - after_size, 0].max
      ratio       = before_size.zero? ? 0.0 : saved.to_f / before_size

      if ratio >= threshold_ratio
        manifest["total_bytes_saved"] += saved
        entry["status"] = "optimized"
        entry["bytes_saved"] = (entry["bytes_saved"] || 0) + saved
        session_saved += saved
        changed << { path: file, saved: saved }
      else
        entry["status"] = "negligible"
        entry["bytes_saved"] ||= 0
        negligible << { path: file, saved: saved }
      end

      entry["hash"] = after_hash
      entry["size"] = after_size
      manifest["files"][file] = entry
    end

    FileUtils.mkdir_p(File.dirname(manifest_path))
    File.write(manifest_path, manifest.to_yaml)

    puts "\n📦 Session summary:"
    changed.each     { |c| puts "  • #{c[:path]}  −#{c[:saved]} bytes" }
    negligible.each  { |n| puts "  • #{n[:path]}  negligible (#{n[:saved]} bytes)" }
    puts "💾 Saved this run: #{session_saved} bytes"
    puts "🧮 Total saved (all time): #{manifest['total_bytes_saved']} bytes"
    puts "✅ Optimization complete."
  end

  desc "Show image optimization stats from manifest"
  task stats: :environment do
    manifest_path = Rails.root.join("config/image_optimization_manifest.yml")
    unless File.exist?(manifest_path)
      puts "ℹ️ No manifest at #{manifest_path}"
      next
    end
    manifest = YAML.load_file(manifest_path) || {}
    total = manifest.dig("total_bytes_saved") || 0
    files = manifest.dig("files") || {}
    puts "🧮 Total bytes saved (all time): #{total}"
    puts "📂 Tracked files: #{files.size}"
  end

  desc "Fail if files changed since last optimize"
  task check: :environment do
    manifest_path = Rails.root.join("config/image_optimization_manifest.yml")
    manifest = File.exist?(manifest_path) ? (YAML.load_file(manifest_path) || {}) : {}
    files = manifest["files"] || {}
    image_dir = Rails.root.join("app/assets/images")

    unoptimized = Dir.glob("#{image_dir}/**/*.{png,jpg,jpeg,webp,gif,svg}").reject do |file|
      files[file] && files[file]["hash"] == Digest::SHA256.hexdigest(File.read(file))
    end

    if unoptimized.any?
      puts "🚫 Unoptimized images detected:"
      puts unoptimized.join("\n")
      exit 1
    else
      puts "✅ All images match the manifest."
    end
  end
end