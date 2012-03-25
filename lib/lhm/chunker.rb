# Copyright (c) 2011 - 2013, SoundCloud Ltd., Rany Keddo, Tobias Bielohlawek, Tobias
# Schmidt

require 'lhm/command'
require 'lhm/sql_helper'

module Lhm
  class Chunker
    include Command
    include SqlHelper

    attr_reader :connection
    attr_accessor :paused

    # Copy from origin to destination in chunks of size `stride`. Sleeps for
    # `throttle` milliseconds between each stride.
    def initialize(migration, connection = nil, options = {})
      @migration = migration
      @connection = connection
      @stride = options[:stride] || 40_000
      @throttle = options[:throttle] || 100
      @start = options[:start] || select_start
      @limit = options[:limit] || select_limit
      @paused = false
    end

    # Copies chunks of size `stride`, starting from `start` up to id `limit`.
    def up_to(&block)
      1.upto(traversable_chunks_size) do |n|
        yield(bottom(n), top(n))
      end
    end

    def traversable_chunks_size
      @limit && @start ? ((@limit - @start + 1) / @stride.to_f).ceil : 0
    end

    def bottom(chunk)
      (chunk - 1) * @stride + @start
    end

    def top(chunk)
      [chunk * @stride + @start - 1, @limit].min
    end

    def copy(lowest, highest)
      "insert ignore into `#{ destination_name }` (#{ columns }) " +
      "select #{ columns } from `#{ origin_name }` " +
      "where `id` between #{ lowest } and #{ highest }"
    end

    def select_start
      start = connection.select_value("select min(id) from #{ origin_name }")
      start ? start.to_i : nil
    end

    def select_limit
      limit = connection.select_value("select max(id) from #{ origin_name }")
      limit ? limit.to_i : nil
    end

    def throttle_seconds
      @throttle / 1000.0
    end

  private

    def destination_name
      @migration.destination.name
    end

    def origin_name
      @migration.origin.name
    end

    def columns
      @columns ||= @migration.intersection.joined
    end

    def validate
      if @start && @limit && @start > @limit
        error("impossible chunk options (limit must be greater than start)")
      end
    end

    def pause!
      self.paused = true
    end

    def continue!
      self.paused = false
    end

    def interruptable
      old_handler = trap("SIGINT") { paused ? super : pause! }
      yield
    ensure
      trap("SIGINT", old_handler)
    end

    def handle_pause
      print "\nChunking is paused [c: continue, t: set throttle, s: set stride, ctrl+c: abort]: "
      case $stdin.gets.strip.downcase
      when "c", "continue"
        continue!
      when "t", "throttle"
        print "Set new throttle value in ms [current: #{@throttle}]: "
        @throttle = $stdin.gets.to_i
        continue!
      when "s", "stride"
        print "Set new stride value [current: #{@stride}]: "
        @stride = $stdin.gets.to_i
        continue!
      end
    end

    def execute
      interruptable do
        up_to do |lowest, highest|
          affected_rows = @connection.update(copy(lowest, highest))

          if paused
            handle_pause
          end

          if affected_rows > 0
            sleep(throttle_seconds)
          end

          print "."
        end
      end
      print "\n"
    end
  end
end
