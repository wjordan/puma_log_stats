# frozen_string_literal: true

require 'puma'
require 'puma/plugin'
require 'json'

# Puma plugin to log server stats whenever the number of
# concurrent requests exceeds a configured threshold.
module LogStats
  class << self
    # Minimum concurrent requests per process that will trigger logging server
    # stats, or nil to disable logging.
    # Default is the max number of threads in the server's thread pool.
    # If this attribute is a Proc, it will be re-evaluated each interval.
    attr_accessor :threshold
    LogStats.threshold = :max

    # Interval between logging attempts in seconds.
    attr_accessor :interval
    LogStats.interval = 1

    # Proc to filter backtraces.
    attr_accessor :backtrace_filter
    LogStats.backtrace_filter = ->(bt) { bt }
  end

  Puma::Plugin.create do
    attr_reader :launcher

    def start(launcher)
      @launcher = launcher
      launcher.events.register(:state) do |state|
        @state = state
        stats_logger_thread if state == :running
      end
    end

    private

    def stats_logger_thread
      Thread.new do
        if Thread.current.respond_to?(:name=)
          Thread.current.name = 'puma stats logger'
        end
        stats_logger_loop while @state == :running
      end
    end

    def stats_logger_loop
      sleep LogStats.interval
      return unless server

      if should_log?
        stats = server_stats
        stats[:threads] = thread_backtraces
        stats[:gc] = GC.stat
        log stats.to_json
      end
    rescue StandardError => e
      log "LogStats failed: #{e}\n  #{e.backtrace.join("\n    ")}"
    end

    def log(str)
      launcher.events.log str
    end

    # Save reference to Server object from the thread-local key.
    def server
      @server ||= Thread.list.map { |t| t[Puma::Server::ThreadLocalKey] }.compact.first
    end

    STAT_METHODS = %i[backlog running pool_capacity max_threads requests_count].freeze
    def server_stats
      STAT_METHODS.select(&server.method(:respond_to?))
                  .map { |name| [name, server.send(name) || 0] }.to_h
    end

    # True if current server load meets configured threshold.
    def should_log?
      threshold = LogStats.threshold
      threshold = threshold.call if threshold.is_a?(Proc)
      threshold = server.max_threads if threshold == :max
      threshold && (server.max_threads - server.pool_capacity) >= threshold
    end

    def thread_backtraces
      worker_threads.map do |t|
        name = t.respond_to?(:name) ? t.name : thread.object_id.to_s(36)
        [name, LogStats.backtrace_filter.call(t.backtrace)]
      end.sort.to_h
    end

    # List all non-idle worker threads in the thread pool.
    def worker_threads
      server.instance_variable_get(:@thread_pool)
            .instance_variable_get(:@workers)
            .reject { |t| t.backtrace.first.match?(/thread_pool\.rb.*sleep/) }
    end
  end
end
