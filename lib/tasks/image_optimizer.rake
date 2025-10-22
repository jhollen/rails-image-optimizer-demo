# lib/tasks/image_optimizer.rake
require "yaml"
require "digest"
require "image_optim"
require "fileutils"

namespace :images do
  desc "Optimize new/changed images, update manifest, and track total bytes saved"
  task optimize: :environment do
    manifest_path = Rails.root.join("config/image_optimization_manifest.yml")

    # Load / init manifest
    manifest =
      if File.exist?(manifest_path)
        YAML.load_file(manifest_path) || {}
      else
        {}
      end

    # Backward-compat: migrate old flat manifest { "path" => "hash" } → new structure
    unless manifest.key?("files")
      files_hash = {}
      manifest.each do |k, v|
        next unless k.is_a?(String) && v.is_a?(String)
        files_hash[k] = { "hash" => v, "size" => nil, "bytes_saved" => 0 }
      end
      manifest = { "files" => files_hash, "total_bytes_saved" => 0 }.merge(manifest.is_a?(Hash) ? {} : {})
    end

    manifest["files"] ||= {}
    manifest["total_bytes_saved"] ||= 0

    image_optim = ImageOptim.new(pngout: false)
    image_dir   = Rails.root.join("app/assets/images")

    changed = []
    session_saved = 0

    Dir.glob("#{image_dir}/**/*.{png,jpg,jpeg,webp,gif}").sort.each do |file|
      before_hash = Digest::SHA256.hexdigest(File.read(file))
      entry       = manifest["files"][file] || { "hash" => nil, "size" => nil, "bytes_saved" => 0 }

      next if entry["hash"] == before_hash # unchanged since last run

      before_size = File.size(file)

      puts "🔍 Optimizing #{file} (#{before_size} bytes)..."
      image_optim.optimize_image!(file) # in-place if it can improve

      after_size = File.size(file)
      after_hash = Digest::SHA256.hexdigest(File.read(file))
      saved      = [before_size - after_size, 0].max

      # Update per-file record
      entry["hash"]         = after_hash
      entry["size"]         = after_size
      entry["bytes_saved"]  = (entry["bytes_saved"] || 0) + saved
      manifest["files"][file] = entry

      # Update totals
      manifest["total_bytes_saved"] = (manifest["total_bytes_saved"] || 0) + saved
      session_saved += saved
      changed << { path: file, saved: saved }
    end

    # Persist manifest
    FileUtils.mkdir_p(File.dirname(manifest_path))
    File.write(manifest_path, manifest.to_yaml)

    # Output
    if changed.empty?
      puts "✅ No changes. All images are up to date."
    else
      puts "\n📦 Session savings:"
      changed.each { |c| puts "  • #{c[:path]}  −#{c[:saved]} bytes" }
      puts "💾 Saved this run: #{session_saved} bytes"
      puts "🧮 Total saved (all time): #{manifest['total_bytes_saved']} bytes"
      puts "✅ Optimization complete. #{changed.size} image(s) processed."
    end
  end

  desc "Show image optimization stats from manifest"
  task stats: :environment do
    manifest_path = Rails.root.join("config/image_optimization_manifest.yml")
    unless File.exist?(manifest_path)
      puts "ℹ️ No manifest found at #{manifest_path}"
      next
    end
    manifest = YAML.load_file(manifest_path) || {}
    total = manifest.dig("total_bytes_saved") || 0
    files = manifest.dig("files") || {}
    puts "🧮 Total bytes saved (all time): #{total}"
    puts "📂 Tracked files: #{files.size}"
  end
end