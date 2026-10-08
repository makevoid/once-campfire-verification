require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "comparison_support"

class BenchmarkExclusionTest < Minitest::Test
  def test_source_fingerprint_covers_the_native_entrypoint_and_new_runtime_files
    helper = Object.new.extend(BenchmarkSupport)
    Dir.mktmpdir do |directory|
      helper.run("git", "-C", directory, "init", "--quiet")
      entrypoint = File.join(directory, "app.rb")
      File.write(entrypoint, "first application")
      helper.run("git", "-C", directory, "add", "app.rb")
      first = helper.source_fingerprint(directory)
      File.write(entrypoint, "changed application")
      changed = helper.source_fingerprint(directory)
      refute_equal first, changed
      File.write(File.join(directory, "README.md"), "documentation")
      assert_equal changed, helper.source_fingerprint(directory)
      FileUtils.mkdir_p(File.join(directory, "lib"))
      File.write(File.join(directory, "lib/new.rb"), "new runtime")
      with_new_file = helper.source_fingerprint(directory)
      refute_equal changed, with_new_file
      File.unlink(entrypoint)
      refute_equal with_new_file, helper.source_fingerprint(directory)
    end
  end

  def test_mixed_profile_rate_is_bounded_before_any_runtime_starts
    command = File.expand_path("../bin/benchmark", __dir__)
    Dir.mktmpdir do |directory|
      [-1, 101].each do |rate|
        _, errors, status = Open3.capture3({ "TMPDIR" => directory }, RbConfig.ruby, command, "--mixed-write-rate", rate.to_s)
        refute status.success?
        assert_includes errors, "mixed write rate must be between 0 and 100"
      end
      output, errors, status = Open3.capture3({ "TMPDIR" => directory }, RbConfig.ruby, command, "--help")
      assert status.success?, errors
      assert_includes output, "--mixed-write-rate"
    end
  end

  def test_another_run_cannot_start_while_the_benchmark_lock_is_held
    Dir.mktmpdir do |directory|
      command = File.expand_path("../bin/benchmark", __dir__)
      File.open(File.join(directory, "once-campfire-verification-benchmark.lock"), "a") do |lock|
        assert lock.flock(File::LOCK_EX | File::LOCK_NB)
        _, errors, status = Open3.capture3({ "TMPDIR" => directory }, RbConfig.ruby, command, "--help")
        refute status.success?
        assert_includes errors, "Another Campfire benchmark is running"
      end
      output, errors, status = Open3.capture3({ "TMPDIR" => directory }, RbConfig.ruby, command, "--help")
      assert status.success?, errors
      assert_includes output, "--apps"
    end
  end
end
