# lib/tasks/seed_images.rake
namespace :images do
  desc "Seed bloated demo images. Usage: rake 'images:seed_bloated[COUNT]' (default 500)"
  task :seed_bloated, [:count] => :environment do |_, args|
    require "fileutils"
    count = (args[:count] || 500).to_i
    dir   = Rails.root.join("app/assets/images/bloated")
    FileUtils.mkdir_p(dir)

    magick = `which magick`.strip
    magick = `which convert`.strip if magick.empty?
    unless File.exist?(magick)
      puts "⚠️ ImageMagick not found (magick/convert). Install with Homebrew or apt."
      exit 1
    end

    puts "🧪 Generating #{count} bloated JPG/PNG images in #{dir}…"
    count.times do |i|
      path =
        if i.odd?
          File.join(dir, "bloat_#{i + 1}.jpg").tap do |p|
            system("#{magick} -size 1200x900 gradient: -evaluate AddModulus #{rand(10000)} " \
                   "-sampling-factor 4:4:4 -quality 100 -interlace none " \
                   "-set comment 'bloat: deliberately huge' '#{p}'")
          end
        else
          File.join(dir, "bloat_#{i + 1}.png").tap do |p|
            system("#{magick} -size 1200x900 gradient: -evaluate AddModulus #{rand(10000)} " \
                   "-depth 16 -define png:compression-level=0 -define png:compression-strategy=0 " \
                   "'#{p}'")
          end
        end
    end

    # Some GIFs
    if system("which gifsicle >/dev/null 2>&1")
      puts "🎞️  Generating 25 bloated GIFs…"
      25.times do |i|
        out = File.join(dir, "bloat_gif_#{i + 1}.gif")
        system("#{magick} -size 400x300 gradient: -evaluate AddModulus #{rand(10000)} GIF:- | gifsicle --delay=5 --loopcount=0 > '#{out}'")
      end
    else
      puts "ℹ️ gifsicle not found — skipping GIFs."
    end

    # Some SVGs
    puts "🖼️  Generating 25 bloated SVGs…"
    25.times do |i|
      out = File.join(dir, "bloat_svg_#{i + 1}.svg")
      File.open(out, "w") do |f|
        f.puts <<~SVG
          <svg xmlns="http://www.w3.org/2000/svg" width="600" height="400">
            <!-- deliberately verbose -->
            #{Array.new(200) { |n| "<rect x='#{n%50*12}' y='#{n/50*12}' width='10' height='10' fill='##{rand(0xffffff).to_s(16).rjust(6,"0")}' opacity='0.5'/>" }.join("\n")}
          </svg>
        SVG
      end
    end

    puts "✅ Seed complete in #{dir}"
  end

  desc "Remove bloated demo images"
  task :clear_bloated => :environment do
    dir = Rails.root.join("app/assets/images/bloated")
    if Dir.exist?(dir)
      require "fileutils"
      FileUtils.rm_rf(dir)
      puts "🧹 Cleared #{dir}"
    else
      puts "ℹ️ Nothing to clear."
    end
  end
end