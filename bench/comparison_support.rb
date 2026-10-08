require "fileutils"
require "json"
require "open3"
require "optparse"
require "digest"

module BenchmarkSupport
  ROOT = File.expand_path("..", __dir__)
  WORK = File.join(ROOT, "tmp/bench")

  def run(*command, input: nil)
    output, errors, status = Open3.capture3(*command, stdin_data: input, binmode: true)
    raise "#{command.first} failed (#{status.exitstatus}): #{errors}" unless status.success?
    output
  end

  # Include dirty and new runtime sources, but not measurements, docs, or tests.
  # Used for build labels as well as receipts, so stale local images fail closed.
  def source_fingerprint(source)
    paths = run("git", "-C", source, "ls-files", "-z", "--cached", "--others", "--exclude-standard").split("\0").uniq.sort
    digest = Digest::SHA256.new
    paths.each do |path|
      next unless path.match?(%r{\A(?:app/|bin/|config/|db/|frontend/|hooks/|lib/|public/|views/|vendor/javascript/|bench/verification/boot\z|bench/verification/App\.Dockerfile\z)}) ||
        %w[app.rb Dockerfile Gemfile Gemfile.lock config.ru Rakefile .ruby-version .dockerignore].include?(path)
      full = File.join(source, path)
      next unless File.file?(full)
      digest << path << "\0" << File.binread(full) << "\0"
    end
    digest.hexdigest
  end

  def remove_container(name)
    Open3.capture3("docker", "rm", "-f", name)
  end

  def prepare_storage(seed, destination)
    FileUtils.rm_rf(destination)
    FileUtils.mkdir_p(destination)
    FileUtils.cp_r(File.join(seed, "db"), File.join(destination, "db"))
    FileUtils.cp_r(File.join(seed, "storage"), File.join(destination, "files"))
    # Disposable fixtures must be writable by the production container UID.
    FileUtils.chmod_R("a+rwX", destination)
  end

  def mounts(paths)
    paths.flat_map { |host, target| [ "-v", "#{host}:#{target}" ] }
  end

  def environment(values)
    values.flat_map { |name, value| [ "-e", "#{name}=#{value}" ] }
  end

  def write_json(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(data) + "\n")
  end

  def median(values)
    values = values.sort
    middle = values.length / 2
    values.length.odd? ? values[middle] : (values[middle - 1] + values[middle]) / 2.0
  end

  def clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
