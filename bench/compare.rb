# Native production comparison. Outputs stay in ignored tmp; never benchmarks a stub app.
require_relative "comparison_support"
require_relative "http_client"
require_relative "validate_acks"
require_relative "contracts"
require "digest"
require "time"
include BenchmarkSupport

repo = File.expand_path("..", __dir__)
workspace = File.dirname(repo)
work = File.join(repo, "tmp/bench")
options = { apps: "rails,roda", rounds: 3, duration: 8, concurrencies: "16", port: 25130,
  workspace: workspace, seed: File.join(repo, "fixtures/default"), preflight: false, keep_runtime: false, mixed_write_rate: 0,
  client_image: ENV.fetch("BENCH_CLIENT_IMAGE", RUBY_PLATFORM.include?("darwin") ? "campfire-verification:local" : ""),
  network: RUBY_PLATFORM.include?("darwin") ? "bridge" : "host",
  loadgen: ENV.fetch("LOADGEN", File.join(repo, "loadgen/target/release/loadgen")),
  env_file: ENV.fetch("BENCH_ENV_FILE", File.join(repo, "fixtures/default/reference.env")),
  output: File.join(work, "results", "#{Time.now.utc.strftime('%Y%m%d-%H%M%S')}-#{Process.pid}"), cpus: "0-3", client_cpus: "4-7",
  routes: "room_show,messages_page,sidebar,search,avatar,static_css,up,post_message" }
OptionParser.new do |parser|
  options.each do |key, default|
    if [true, false].include?(default)
      parser.on("--#{key}") { options[key] = true }
    else
      type = default.is_a?(Integer) ? Integer : String
      parser.on("--#{key.to_s.tr('_', '-')} VALUE", type) { |value| options[key] = value }
    end
  end
  parser.on("--help") { puts parser; exit }
end.parse!
raise "use at least two rounds" unless options[:rounds] >= 2
apps = options[:apps].split(",")
allowed = %w[rails roda django laravel express express-bun elixir go rust c cpp]
raise "apps must be nonempty, unique and supported" unless !apps.empty? && apps.uniq == apps && apps.all? { |app| allowed.include?(app) }
selected_routes = options[:routes].split(",")
raise "unknown or empty route selection" unless !selected_routes.empty? && (selected_routes - %w[room_show messages_page sidebar search avatar static_css up post_message]).empty?
raise "duration and concurrencies must be positive" unless options[:duration].positive? && !options[:concurrencies].split(",").empty? && options[:concurrencies].split(",").all? { |value| Integer(value).positive? }
raise "mixed write rate must be between 0 and 100" unless (0..100).cover?(options[:mixed_write_rate])
mixed = options[:mixed_write_rate].positive?
if mixed
  selected_routes &= %w[room_show messages_page sidebar search]
  raise "mixed profile requires a read route" if selected_routes.empty?
end
runtimes = apps.to_h { |app| [app, app == "express-bun" ? "express" : app] }
env_name = ->(app) { app.upcase.tr("-", "_") }
labels = JSON.parse(File.read(File.join(options[:seed], "labels.json")))
original_seed_sha = Digest::SHA256.file(File.join(options[:seed], "db/production.sqlite3")).hexdigest
room = Integer(labels.fetch("rooms.watercooler"))
write_room = Integer(labels.fetch("rooms.hq"))
base = "http://127.0.0.1:#{options[:port]}"
raise "output already exists: #{options[:output]}" if File.exist?(options[:output])
sample_number = 0
container = "cf-native-bench-#{Process.pid}"
runtime_data = nil
fixture_env = File.readlines(options[:env_file], chomp: true).reject { |line| line.empty? || line.start_with?("#") }.to_h { |line| line.split("=", 2) }
lg = ->(*args) do
  started = clock
  cpu_before = Process.times
  command = if options[:client_image].empty?
    ["taskset", "-c", options[:client_cpus], options[:loadgen], *args]
  else
    ["docker", "run", "--rm", "--network", "container:#{container}", "--cpuset-cpus", options[:client_cpus],
      "-v", "#{runtime_data}:#{runtime_data}", "--entrypoint", "/usr/local/bin/loadgen", options[:client_image], *args]
  end
  output, errors, status = Open3.capture3(*command)
  if ENV["LOADGEN_DEBUG"]
    FileUtils.mkdir_p(work)
    File.open(File.join(work, "loadgen-debug-#{Process.pid}.log"), "ab") { |file| file.write(errors) }
  end
  raise "load generator failed: #{errors}" unless status.success?
  value = JSON.parse(output)
  if args.first == "http"
    cpu_after = Process.times
    value["generator_cpu_percent"] = options[:client_image].empty? ? 100.0 * (cpu_after.cutime + cpu_after.cstime - cpu_before.cutime - cpu_before.cstime) / (clock - started) : nil
    sample_number += 1
    write_json(File.join(options[:output], "raw", "http-#{sample_number}.json"), value)
  end
  value
end
results = []
metadata = { verification_revision: run("git", "-C", repo, "rev-parse", "HEAD").strip,
  verification_patch_sha256: Digest::SHA256.hexdigest(run("git", "-C", repo, "diff", "--binary", "HEAD")),
  response_validation: "route-contract-v1", contract_source: "shared Rails fixture SQL",
  fixture_normalizations: ["outbound endpoints to loopback discard port", "missing creators represented by disabled users in every runtime"], started_at: Time.now.utc.iso8601, seed_sha256: original_seed_sha, server_cpus: options[:cpus],
  client_cpus: options[:client_cpus], network: options[:network],
  client_image: options[:client_image].empty? ? nil : run("docker", "image", "inspect", "-f", "{{.Id}}", options[:client_image]).strip, gzip: true, duration: options[:duration],
  concurrencies: options[:concurrencies], rounds: options[:rounds], loadgen_sha256: options[:client_image].empty? ? Digest::SHA256.file(options[:loadgen]).hexdigest : run("docker", "run", "--rm", "--entrypoint", "sha256sum", options[:client_image], "/usr/local/bin/loadgen").split.first,
  routes: selected_routes.join(","), profile: mixed ? "mixed-read-write-v1" : "read-and-post-v1",
  mixed_writer: mixed ? {clients: 1, maximum_writes_per_second: options[:mixed_write_rate], room: write_room, catch_up: false} : nil, images: {}, image_labels: {}, source_revisions: {}, preflight_only: options[:preflight] }
sql = ->(db, query) do
  readonly = query.match?(/\ASELECT/i)
  output = run("sqlite3", "-cmd", ".timeout 10000", *(readonly ? ["-readonly"] : []), "-json", db, query)
  output.strip.empty? ? [] : JSON.parse(output)
end
check_sample = ->(name, value) do
  raise "#{name}: unsuccessful requests #{value}" unless value.fetch("errors").zero? && value.fetch("invalid_responses").zero? && value.fetch("validation") == "route-contract-v1" && value.fetch("ok") > 0 && value.fetch("statuses") == { "200" => value.fetch("ok") }
end
begin
  options[:rounds].times do |iteration|
    order = iteration.even? ? apps : apps.reverse
    order.each do |app|
      kind = runtimes.fetch(app)
      images = { "rails" => "once-campfire:app", "rust" => "campfire-rust:app", "elixir" => "campfire-elixir:app", "express-bun" => "once-campfire-express:bun" }
      image = ENV.fetch("#{env_name.(app)}_IMAGE", images.fetch(app, "once-campfire-#{app}:app"))
      source = ENV.fetch("#{env_name.(app)}_SOURCE", File.join(options[:workspace], kind == "rails" ? "once-campfire" : "once-campfire-#{kind}"))
      image_id = run("docker", "image", "inspect", "-f", "{{.Id}}", image).strip
      raise "#{app}: image changed between rounds" if metadata[:images].key?(app) && metadata[:images][app] != image_id
      metadata[:images][app] = image_id
      metadata[:image_labels][app] = JSON.parse(run("docker", "image", "inspect", "-f", "{{json .Config.Labels}}", image))
      source_identity = { head: run("git", "-C", source, "rev-parse", "HEAD").strip,
        tracked_dirty: !run("git", "-C", source, "status", "--porcelain", "--untracked-files=no").strip.empty?,
        dirty: !run("git", "-C", source, "status", "--porcelain").strip.empty?, runtime_sha256: source_fingerprint(source) }
      if expected = metadata[:image_labels][app]&.fetch("io.campfire.source.sha256", nil)
        raise "#{app}: image was built from different runtime files" unless expected == source_identity[:runtime_sha256]
      end
      raise "#{app}: source changed between rounds" if metadata[:source_revisions].key?(app) && metadata[:source_revisions][app] != source_identity
      metadata[:source_revisions][app] = source_identity
      data = File.join(work, "runtime", Process.pid.to_s, "#{app}-#{iteration + 1}")
      runtime_data = data
      prepare_storage(options[:seed], data)
      FileUtils.mkdir_p(File.join(data, "logs"))
      FileUtils.chmod(0o777, File.join(data, "logs"))
      db = File.join(data, "db/production.sqlite3")
      contract_db = db
      sql.call(db, "PRAGMA user_version=1;") if kind == "c"
      sql.call(db, "UPDATE push_subscriptions SET endpoint = 'https://127.0.0.1:9/push/' || id; UPDATE webhooks SET url = 'http://127.0.0.1:9/hook/' || id;")
      # The visual fixture deliberately has a message with an absent creator.
      # Keep its ID/body and add the same disabled author to every HTTP runtime;
      # native schemas with foreign keys can then import the complete fixture.
      sql.call(db, "INSERT INTO users(id,name,role,status,created_at,updated_at) SELECT DISTINCT m.creator_id,'Deleted user',0,1,'1970-01-01 00:00:00','1970-01-01 00:00:00' FROM messages m LEFT JOIN users u ON u.id=m.creator_id WHERE u.id IS NULL;")
      raise "invalid seed" unless sql.call(db, "SELECT COUNT(*) AS n FROM messages WHERE room_id=#{room}").first.fetch("n") > 50
      initial_max_id = sql.call(db, "SELECT MAX(id) AS id FROM messages").first.fetch("id")
      initial_messages = sql.call(db, "SELECT COUNT(*) AS n FROM messages WHERE room_id=#{write_room}").first.fetch("n")
      config = fixture_env.merge("WEB_CONCURRENCY" => "3", "JOB_CONCURRENCY" => "3", "RAILS_MAX_THREADS" => "5",
        "RAILS_LOG_LEVEL" => "warn", "RUBY_YJIT_ENABLE" => "1", "HTTP_PORT" => options[:port].to_s, "TARGET_PORT" => (options[:port] + 1).to_s)
      config.merge!(JSON.parse(ENV.fetch("#{env_name.(app)}_BENCH_ENV", "{}")))
      # Host-network comparisons may coexist with a release verification node.
      config["RELEASE_NODE"] = container if kind == "elixir"
      metadata[:topology] ||= {}
      metadata[:runtimes] ||= {}
      metadata[:runtimes][app] = runtimes.fetch(app)
      metadata[:topology][app] = case kind
      when "roda" then {http_workers: config.fetch("WEB_CONCURRENCY"), threads: config.fetch("RAILS_MAX_THREADS"), jobs: "durable SQLite", cable: "native websocket"}
      when "rails" then {http_workers: config.fetch("WEB_CONCURRENCY"), threads: config.fetch("RAILS_MAX_THREADS"), jobs: "Redis/Resque", cable: "Action Cable"}
      when "rust" then {processes: 1, readers: config.fetch("RAILS_MAX_THREADS"), job_workers: config.fetch("JOB_CONCURRENCY"), cable: "native tokio", jobs: "in-process"}
      when "go" then {processes: 1, cable: "native websocket", jobs: "in-process"}
      when "elixir" then {processes: 1, runtime: "BEAM", jobs: "Redis/Resque", cable: "native"}
      when "express" then {http_workers: config.fetch("WEB_WORKERS", "auto (cpuset)"), cable: "native ws with cluster IPC", jobs: "leased auxiliary SQLite"}
      when "laravel" then {http: "FrankenPHP/Octane", jobs: "leased auxiliary SQLite", cable: "native ReactPHP"}
      when "c" then {processes: 1, http_loops: config.fetch("CF_LOOPS", "affinity, capped at 4"), cache_bytes: config.fetch("CF_CACHE_BYTES", "67108864"), jobs: "in-process"}
      when "cpp" then {processes: 1, page_cache_mb: config.fetch("CAMPFIRE_PAGE_CACHE_MB", "32"), cable: "native", jobs: "in-process"}
      when "django" then {http_workers: config.fetch("WEB_WORKERS", config["REDIS_URL"].to_s.empty? ? "1" : "affinity, capped at 4"), runtime: "ASGI/Uvicorn", cable: "native", jobs: "leased auxiliary SQLite"}
      end
      unless %w[c cpp].include?(kind)
        metadata[:topology][app][:response_cache_mb] = config.fetch("CAMPFIRE_RESPONSE_CACHE_MB", "64")
      end
      metadata[:topology][app][:yjit] = config.fetch("RUBY_YJIT_ENABLE") if %w[rails roda].include?(kind)
      metadata[:topology][app][:fragment_cache_mb] = config.fetch("CAMPFIRE_FRAGMENT_CACHE_MB", "64") if kind == "roda"
      command = ["docker", "run", "-d", "--name", container, "--network", options[:network], "--cpuset-cpus", options[:cpus]]
      command.concat ["-p", "127.0.0.1:#{options[:port]}:#{options[:port]}"] unless options[:network] == "host"
      command.concat environment(config)
      command.concat mounts(File.join(data, "db") => "/rails/storage/db", File.join(data, "files") => "/rails/storage/files", File.join(data, "logs") => "/rails/storage/logs")
      command << image_id
      run(*command)
      client = BenchmarkHTTPClient.new(base)
      deadline = clock + 90
      until client.ready?
        if clock > deadline
          FileUtils.mkdir_p(options[:output])
          logs = File.join(options[:output], "#{app}-#{iteration + 1}-startup.log")
          output, errors, = Open3.capture3("docker", "logs", container)
          File.write(logs, output + errors)
          raise "#{app} failed to start; inspect #{logs}"
        end
        sleep 0.1
      end
      run("docker", "exec", "--user", "root", container, "chmod", "-R", "a+rwX", "/rails/storage/db")
      if kind == "roda"
        db = File.join(data, "db/roda.sqlite3")
        # Native storage contains the same imported IDs/content. Contracts query
        # that storage directly; only signed avatar URLs use Roda's token format.
        avatar_script = 'require_relative "lib/campfire"; puts Campfire::Tokens.new(ENV.fetch("SECRET_KEY_BASE")).generate(Integer(ARGV.fetch(0)), purpose: :avatar)'
        app_labels = labels.merge("avatar_tokens.jason" => run("docker", "exec", container, "bundle", "exec", "ruby", "-e", avatar_script, labels.fetch("users.jason").to_s).strip)
        imported_count = sql.call(db, "SELECT COUNT(*) AS n FROM messages WHERE room_id=#{write_room}").first.fetch("n")
        raise "import changed the write-room fixture" unless imported_count == initial_messages
      else
        app_labels = labels
      end
      sleep 3 unless options[:preflight]
      cookie = lg.call("login", "--base", base, "--email", labels.fetch("emails.david"), "--password", labels.fetch("passwords.all")).fetch("cookie")
      scrape = lg.call("scrape", "--base", base, "--cookie", cookie, "--room", room.to_s)
      # Browser metadata protects current apps; tokens remain optional for historical references.
      csrf = scrape.fetch("csrf").to_s
      routes = { "room_show" => "/rooms/#{room}", "messages_page" => "/rooms/#{room}/messages?before=#{labels.fetch('messages.busy_060')}",
        "sidebar" => "/users/me/sidebar", "search" => "/searches?q=coffee", "avatar" => "/users/#{app_labels.fetch('avatar_tokens.jason')}/avatar",
        "static_css" => scrape.fetch("css"), "up" => "/up", "post_message" => nil }
      prepared = BenchmarkContracts.prepare(base, cookie, contract_db, app_labels, scrape.fetch("css"), File.join(data, "contracts"))
      contracts = prepared.fetch(:contracts)
      preflight = prepared.fetch(:preflight)
      row = { app: app, round: iteration + 1, preflight: preflight, http: [], mixed_http: [], load_start: File.file?("/proc/loadavg") ? File.read("/proc/loadavg").strip : nil }
      acknowledged_writes = 0
      write_audits = []
      unless options[:preflight]
        routes.each do |name, path|
          next unless selected_routes.include?(name)
          args = (path ? ["--path", path] : ["--post-room", write_room.to_s, "--csrf", csrf]) + ["--validate", contracts.fetch(name)]
          warm_audit = []
          unless path
            audit = File.join(data, "post-warmup-#{name}.jsonl")
            write_audits << audit
            warm_audit = ["--audit-writes", audit]
          end
          mixed_args = ->(phase) do
            next [] unless mixed
            audit = File.join(data, "mixed-#{name}-#{phase}.jsonl")
            write_audits << audit
            ["--mixed-write-rate", options[:mixed_write_rate].to_s, "--mixed-write-room", write_room.to_s,
              "--mixed-write-validate", contracts.fetch("post_message"), "--mixed-write-audit", audit, "--csrf", csrf]
          end
          warmup = lg.call("http", "--base", base, "--cookie", cookie, *args, *warm_audit, *mixed_args.call("warmup"), "--conc", "4", "--duration", "2")
          check_sample.call(name, warmup)
          if mixed
            check_sample.call("#{name} warmup writer", warmup.fetch("writer"))
            acknowledged_writes += warmup.fetch("writer").fetch("ok")
          end
          acknowledged_writes += warmup.fetch("ok") unless path
          options[:concurrencies].split(",").each do |concurrency|
            timed_audit = []
            unless path
              audit = File.join(data, "post-#{concurrency}.jsonl")
              write_audits << audit
              timed_audit = ["--audit-writes", audit]
            end
            value = lg.call("http", "--base", base, "--cookie", cookie, *args, *timed_audit, *mixed_args.call(concurrency), "--conc", concurrency, "--duration", options[:duration].to_s)
            check_sample.call(name, value)
            acknowledged_writes += value.fetch("ok") unless path
            if mixed
              check_sample.call("#{name} timed writer", value.fetch("writer"))
              acknowledged_writes += value.fetch("writer").fetch("ok")
            end
            row[mixed ? :mixed_http : :http] << value.merge("route" => name)
            puts "#{app} round #{iteration + 1}: #{name} #{concurrency} clients #{value.fetch('rps')} req/s"
            STDOUT.flush
          end
        end
      end
      actual_messages = sql.call(db, "SELECT COUNT(*) AS n FROM messages WHERE room_id=#{write_room}").first.fetch("n")
      raise "acknowledged HTTP write count mismatch" unless actual_messages - initial_messages == acknowledged_writes
      raise "FTS entry missing" unless sql.call(db, "SELECT COUNT(*) AS n FROM messages WHERE id NOT IN (SELECT rowid FROM message_search_index)").first.fetch("n").zero?
      raise "rich text entry missing" unless kind == "roda" || sql.call(db, "SELECT COUNT(*) AS n FROM messages WHERE room_id=#{write_room} AND id>#{initial_max_id} AND id NOT IN (SELECT record_id FROM active_storage_attachments WHERE record_type='Message') AND id NOT IN (SELECT record_id FROM action_text_rich_texts WHERE record_type='Message' AND name='body')").first.fetch("n").zero?
      raise "fixture corrupt" unless sql.call(db, "PRAGMA integrity_check;").first.values == ["ok"]
      richtext_query = if kind == "roda"
        "SELECT COUNT(*) AS n FROM messages WHERE room_id=#{write_room} AND id>#{initial_max_id} AND body LIKE '%bench write %'"
      else
        "SELECT COUNT(*) AS n FROM messages m JOIN action_text_rich_texts rt ON rt.record_type='Message' AND rt.record_id=m.id AND rt.name='body' WHERE m.room_id=#{write_room} AND m.id>#{initial_max_id} AND rt.body LIKE '%bench write %'"
      end
      richtext_posts = sql.call(db, richtext_query).first.fetch("n")
      raise "acknowledged message body missing" if richtext_posts != acknowledged_writes
      row[:post_write_audit] = AcknowledgedWrites.verify(db, write_room, write_audits, acknowledged_writes, schema: kind == "roda" ? :roda : :rails)
      row[:richtext_http_posts] = richtext_posts
      row[:persisted_writes] = actual_messages - initial_messages
      row[:load_end] = File.file?("/proc/loadavg") ? File.read("/proc/loadavg").strip : nil
      results << row
      write_json(File.join(options[:output], "#{app}-#{iteration + 1}.json"), row)
      remove_container(container)
      FileUtils.rm_rf(data) unless options[:keep_runtime]
    end
  end
  raise "original seed changed" unless Digest::SHA256.file(File.join(options[:seed], "db/production.sqlite3")).hexdigest == original_seed_sha
  summary = apps.to_h do |app|
    rows = results.select { |row| row[:app] == app }
    summary_routes = mixed ? %w[room_show messages_page sidebar search] : %w[room_show messages_page sidebar search post_message]
    values = summary_routes.to_h do |name|
      samples = rows.filter_map { |row| row[mixed ? :mixed_http : :http].find { |item| item.fetch("route") == name && item.fetch("conc") == 16 }&.fetch("rps") }
      [name, samples.empty? ? nil : { median_rps: median(samples), runs: samples }]
    end
    [app, values]
  end
  metadata[:complete] = true
  write_json(File.join(options[:output], mixed ? "mixed-summary.json" : "summary.json"), metadata: metadata,
    (mixed ? :mixed_results : :results) => summary)
  puts JSON.pretty_generate(summary)
ensure
  remove_container(container)
end
