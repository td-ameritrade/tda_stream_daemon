require 'tdameritrade_api'

module TDAStreamDaemon
  module Calculations
    TIME_BUCKETS_5MIN=(930..2000).to_a.select { |n| ((n % 5) == 0) && (n % 100 < 60) }

    def calculate_true_range(previous_candle, current_candle)
      [current_candle[:high] - current_candle[:low],
       current_candle[:high] - previous_candle[:close],
       previous_candle[:close] - current_candle[:low]].max.to_f
    end

    # rounds up the time value given by the TDA server to the nearest 5 minute mark
    def calculate_time_bucket(seconds)
      Time.at((seconds.to_f / (5 * 60)).floor * 60 * 5 + 60 * 5).utc.strftime("%k%M").to_i
    end

    def calculate_time_number(seconds)
      Time.at(seconds).utc.strftime("%k%M").to_i
    end
  end


  class SymbolDataStoreList
    attr_accessor :data_stores

    def initialize
      @data_stores = Array.new
    end

    def add(data_store)
      #raise Exception.new("Need a Datastore object") if !data_store.is_a?(SymbolDataStore)
      index = find_store(data_store.symbol)
      if index
        @data_stores[index] = data_store
      else
        @data_stores << data_store
      end
    end

    def [](key)
      if find_store(key)
        @data_stores[find_store(key)]
      end
    end

    def []=(key, value)
      #raise Exception.new("Need a Datastore object") if !value.is_a?(SymbolDataStore)
      if find_store(key)
        [key]
      else
        @data_stores
      end
    end

    private

    def find_store(key)
      @data_stores.each_with_index do |store, i|
        return i if store.symbol==key.to_sym
      end
      nil
    end
  end

  class SymbolDataStore
    include Calculations
    attr_accessor :symbol, :average_true_range, :alert_triggered_time, :close_price

    def initialize(symbol)
      @symbol = symbol.to_sym
      @candle_stack = Array.new  # Candle stack should be an array of Candle objects
    end

    def current_candle
      @candle_stack.last
    end

    def current_candle=(value)
      @candle_stack.pop
      @candle_stack << value
    end

    def candle_stack
      @candle_stack
    end

    def candle_stack=(value)
      @candle_stack=value

      # set the after hours close
      @close_price = @candle_stack.inject(@candle_stack.first) { |last_candle, current_candle| current_candle.time_bucket == 1600 ? current_candle : last_candle }.close
    end

    def previous_candle
      @candle_stack[-2]
    end

    def replace_current_candle(new_candle)
      new_candle.true_range = calculate_true_range(@candle_stack.last, new_candle)
      @candle_stack.shift
      @candle_stack << new_candle
      update_average_true_range
      @close_price = new_candle.close if new_candle.time_bucket == 1600

      if self.afterhours_starting_volume==0 && new_candle.time_bucket>1605 && new_candle.volume
        @afterhours_starting_volume = new_candle.volume
      end
    end

    def update_current_candle(new_candle)
      new_candle.true_range = calculate_true_range(@candle_stack.last, new_candle)
      @candle_stack[-1] = new_candle
      update_average_true_range
      @close_price = new_candle.close if new_candle.time_bucket == 1600
    end

    def true_range
      calculate_true_range(@candle_stack[-2], @candle_stack[-1])
    end

    def afterhours_starting_volume
      @afterhours_starting_volume.nil? ? 0 : @afterhours_starting_volume
    end

    def afterhours_alert_ok?
      if self.afterhours_starting_volume > 0 && @candle_stack[-1].volume.is_a?(Numeric) && @candle_stack[-1].volume - afterhours_starting_volume > 15000
        true
      else
        false
      end
    end

    def alert_triggered_time
      @alert_triggered_time.nil? ? 0 : @alert_triggered_time
    end

    private
    def update_average_true_range
      @average_true_range = @candle_stack.each_cons(2).to_a.map { |candle_pair| calculate_true_range(candle_pair[0], candle_pair[1]) }.inject { |sum, n| sum + n } / @candle_stack.length
    end

  end

  class Candle
    include Calculations
    attr_accessor :high, :low, :close, :volume, :time, :true_range

    def [](key)
      send key
    end

    def []=(key, value)
      send "#{key}=", value
    end

    def time
      @time.nil? ? 0 : @time
    end

    # rounds up the time value given by the TDA server to the nearest 5 minute mark
    def time_bucket
      time ? calculate_time_bucket(time) : 0
    end

  end

  class StreamDaemon
    include Calculations

    attr_accessor :alerts
    attr_reader :watchlist, :watchlist_exclusions  # mainly for debug purposes

    def initialize
      @watchlist = SymbolDataStoreList.new # A hash of each symbol we are watching. Value column will be a hash of the data associated
      @watchlist_exclusions = Array.new
      @alerts = Hash.new # symbol, with the time of the alert
      @tda_client = TDAmeritradeApi::Client.new
      raise Exception.new("Unable to connect to TD Ameritrade API") if !@tda_client.login
    end

    def last_calibration_date
      wl_file = File.join(Dir.pwd, 'cache', 'atrs.txt')
      f = File.open(wl_file, 'r')
      lines = f.read().split("\n")
      f.close
      begin
        Date.parse(lines.shift) # date is the first line
      rescue
        return 0
      end
    end

    def download_average_true_range_calibration(to_calibrate_date)
      filename = File.join(Dir.pwd, 'cache', 'atrs.txt')
      puts "Getting calibration data for true range moving average - #{to_calibrate_date}"
      i = 0
      f = open(filename, 'w')
      f.write("#{to_calibrate_date}\n")
      symbols_from_watchlist.each do |symbol|
        end_date = to_calibrate_date

        attempt = 0
        while attempt < 3
          begin
            prices = @tda_client.get_price_history(symbol, intervaltype: :minute, intervalduration: 5, periodtype: :day, period: 3, enddate: end_date, extended: true).first[:bars].pop(61)
            if prices.count < 61
              puts "Skipping symbol #{symbol} - too few candles returned"
              attempt = 3
              next
            end
            candle_stack = prices.map { |p| "#{p[:high]},#{p[:low]},#{p[:close]}" }.join(';')
            f.write("#{symbol}:#{candle_stack}\n")
            attempt = 3
          rescue
            attempt += 1
            puts "Error retrieving data on #{symbol} (attempt ##{attempt})"
          end
        end
      end

      f.close
    end

    def calibrate_average_true_range(to_calibrate_date, opt={})
      download_average_true_range_calibration(to_calibrate_date) if opt[:skip_calibration_download] != true

      wl_file = File.join(Dir.pwd, 'cache', 'atrs.txt')
      f = File.open(wl_file, 'r')
      lines = f.read().split("\n")
      f.close
      lines.shift # first line is calibration date
      lines.each do |line|
        symbol, candle_stack = line.split(':')
        symbol_properties = SymbolDataStore.new(symbol)
        symbol_properties.candle_stack = candle_stack.split(';').map { |candle| c = Candle.new; c[:high], c[:low], c[:close] = candle.split(',').map(&:to_f); c }
        @watchlist.add(symbol_properties)
      end
    end



    # Run the alerts daemon to notify of parabolics and washes
    # The parameter stream is a TDAmeritradeApi::Streamer object
    def run(stream, opt={})
      # Get yesterday's 5-min charts for each item on the watchlist to set the average true range
      # opt[:stream_date] will be the day that the stream is supposed to be happening (default is today)
      # stream.symbols will be the watchlist of 5min charts we need to pull up

      symbols = symbols_from_watchlist
      calibration_date = opt[:stream_date] || Date.new(2014,8,12)
      stop_time = opt[:stop_time]
      calibrate_average_true_range(calibration_date, opt)
      symbols = symbols.select { |s| !@watchlist[s].nil? }
      i = 1

      while true
        begin
          stream.run(symbols: symbols, request_fields: [:volume, :last, :symbol, :quotetime, :tradetime]) do |data|
            # for each stream record
            # 1. Skip it if the timestamp is not up to date.
            # 2. Calculate the current true range
            # 3. Calculate the average true range
            # 4. Process alert
            #   - if it meets the alert criteria, send it if it hasn't been alerted in the last 20 min

            next if data.columns.nil? || data.columns[:symbol].nil? || data.columns[:last].nil?
            symbol = data.columns[:symbol].to_sym
            next if @watchlist[symbol].nil? # this wasn't on the watchlist so we haven't calculated an average true range for it

            # Need a time with this or its no good to us
            next if data.columns[:quotetime].nil? || (data.columns[:tradetime] && (data.columns[:tradetime] != data.columns[:quotetime]))
            time = data.columns[:quotetime]
            time_bucket = calculate_time_bucket(time)
            puts "Processing current time #{calculate_time_number(time)}, (bucket #{time_bucket}), #{Time.now}" if i % 10000 == 0
            if stop_time && (time_bucket >= stop_time + 5)
              puts "Stopping stream per scheduled stop time: #{stop_time}"
              stream.quit
              return
            end

            if time_bucket == @watchlist[symbol].current_candle.time_bucket
              #the time bucket on the currently received data is the same than the current candle; update the current candle
              current_candle = @watchlist[symbol].current_candle

              # This 'if' statement here was added 2/14/15. It will now only replace the current candle if the high
              # or low has been breached. It has reduced the processing time of 10,000 records from ~44 seconds
              # to ~36 seconds. The "last" calculation may be slightly off now for the ATR calculation, but the
              # difference should be negligible enough that the CPU efficiency is more important.
              if data.columns[:last] > current_candle.high || data.columns[:last] < current_candle.low
                new_candle = Candle.new
                new_candle.close = data.columns[:last]
                new_candle.high = [data.columns[:last], current_candle.high].max
                new_candle.low = [data.columns[:last], current_candle.low].min
                new_candle.volume = data.columns[:volume] if data.columns[:volume]
                new_candle.time = time
                @watchlist[symbol].update_current_candle(new_candle)
              end

            elsif time_bucket > @watchlist[symbol].current_candle.time_bucket
              #the time bucket on the currently received data is greater than the current candle; we have a new currentcandle
              new_candle = Candle.new
              new_candle.close = data.columns[:last]
              new_candle.high = data.columns[:last] # on a brand new candle, we don't have any range yet
              new_candle.low = data.columns[:last] # on a brand new candle, we don't have any range yet
              new_candle.volume = data.columns[:volume] if data.columns[:volume]
              new_candle.time = time

              @watchlist[symbol].replace_current_candle(new_candle)
            end

            #time_number = Time.at(time).utc.strftime("%k%M").to_i
            if time_bucket > 950 && time_bucket < 1600
              # For normal market hours I want to use the average true range to trigger and alert
              if @watchlist[symbol].true_range > (@watchlist[symbol].average_true_range * 5)
                do_alert(symbol, time_bucket, time: Time.at(time).utc.strftime("%k%M").to_i, after_hours_ok: true, last: data.columns[:last], volume: data.columns[:volume], true_range: @watchlist[symbol].true_range, avg_true_range_5: @watchlist[symbol].average_true_range * 5)
              end
            elsif time_bucket >= 1604 && time_bucket < 2000
              # For after market hours I want to use % change > 5% as an alert trigger
              if !@watchlist[symbol].close_price.nil? && ((@watchlist[symbol].current_candle.close / @watchlist[symbol].close_price) - 1).abs >  0.05
                do_alert(symbol, time_bucket, time: Time.at(time).utc.strftime("%k%M").to_i, after_hours_ok: @watchlist[symbol].afterhours_alert_ok?, last: data.columns[:last], volume: data.columns[:volume], true_range: @watchlist[symbol].true_range, avg_true_range_5: @watchlist[symbol].average_true_range * 5)
              end
            end

            #puts "#{i} + #{data.columns} + #{@watchlist[symbol].current_candle.time_bucket} #{@watchlist[symbol].true_range.round(4)} / #{(@watchlist[symbol].average_true_range * 5).round(4)}"
            i += 1
          end


        rescue Exception => e
          # This idiom of a rescue block you can use to reset the connection if it drops,
          # which can happen easily during a fast market.
          if e.class == Errno::ECONNRESET
            puts "Connection reset, reconnecting..."
          else
            raise e
          end
        end

      end

    end

    private

    def do_alert(symbol, time, properties={})
      #TODO move the time screening logic back to the run_daemon calling routine
      #return if time < 950 || time > 1800 || (time > 1605 && !properties[:after_hours_ok])
      return if time < 950 || time > 1800 || (time > 1600 && !properties[:after_hours_ok])
      #return if time < 1605 || (time > 1605 && !properties[:after_hours_ok])

      if (time - @watchlist[symbol].alert_triggered_time > 30) && (@watchlist[symbol].alert_triggered_time < 1600)
        puts "Alert on #{symbol.to_s} at #{time}: #{properties}"
        system "say 'Price action in #{symbol.to_s.bytes.map(&:chr).join('-')}'"
        @watchlist[symbol].alert_triggered_time = time
        sleep 5
      end
    end

    def calculate_average_true_range(candle_stack)
      candle_stack.each_cons(2).to_a.map { |p| calculate_true_range(p[0], p[1]) }.inject { |sum, tr| sum + tr }.to_f / 30
    end

    def calculate_true_range(previous_candle, current_candle)
      [current_candle[:high] - current_candle[:low],
       current_candle[:high] - previous_candle[:close],
       previous_candle[:close] - current_candle[:low]].max
    end

    def symbols_from_watchlist
      wl_file = File.join(Dir.pwd, 'run', 'watchlist.txt')
      f = File.open(wl_file, 'r')
      list = f.read().split("\n")
      f.close
      list
    end

  end
end