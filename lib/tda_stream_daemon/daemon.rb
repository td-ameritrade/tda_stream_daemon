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
  end


  class SymbolDataStoreList
    attr_accessor :data_stores

    def initialize
      @data_stores = Array.new
    end

    def add(data_store)
      raise Exception.new("Need a Datastore object") if !data_store.is_a?(SymbolDataStore)
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
      raise Exception.new("Need a Datastore object") if !value.is_a?(SymbolDataStore)
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
    attr_accessor :symbol, :candle_stack, :average_true_range, :alert_triggered_time

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

    def previous_candle
      @candle_stack[-2]
    end

    def replace_current_candle(new_candle)
      @candle_stack.shift
      @candle_stack << new_candle
    end

    def update_current_candle(new_candle)
      @candle_stack[-1] = new_candle
    end

    def true_range
      calculate_true_range(@candle_stack[-2], @candle_stack[-1])
    end

    def average_true_range
      @candle_stack.each_cons(2).to_a.map { |candle_pair| calculate_true_range(candle_pair[0], candle_pair[1]) }.inject { |sum, n| sum + n } / @candle_stack.length
    end

    def alert_triggered_time
      @alert_triggered_time.nil? ? 0 : @alert_triggered_time
    end

  end

  class Candle
    include Calculations
    attr_accessor :high, :low, :close, :volume, :time

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
    attr_reader :watchlist  # mainly for debug purposes

    def initialize
      @watchlist = SymbolDataStoreList.new # A hash of each symbol we are watching. Value column will be a hash of the data associated
      @alerts = Hash.new # symbol, with the time of the alert
      @tda_client = TDAmeritradeApi::Client.new
      raise Exception.new("Unable to connect to TD Ameritrade API") if !@tda_client.login
    end

    # Run the alerts daemon to notify of parabolics and washes
    # The parameter stream is a TDAmeritradeApi::Streamer object
    def run(stream, opt={})
      # Get yesterday's 5-min charts for each item on the watchlist to set the average true range
      # opt[:stream_date] will be the day that the stream is supposed to be happening (default is today)
      # stream.symbols will be the watchlist of 5min charts we need to pull up

      save_atrs = false
      symbols = symbols_from_watchlist

      filename = File.join(Dir.pwd, 'run', 'atrs.txt')
      if save_atrs then
        puts "Getting data for true range moving average"
        i = 0
        f = open(filename, 'w')
        symbols.each do |symbol|
          opt.has_key?(:stream_date) ? end_date = opt[:stream_date]-1 : end_date = Date.new(2014,8,11)
          begin
            prices = @tda_client.get_price_history(symbol, intervaltype: :minute, intervalduration: 5, periodtype: :day, period: 1, enddate: end_date).pop(61)
            #average_true_range = calculate_average_true_range(prices)
            # build the stack of true ranges
            #true_range_stack = prices.each_cons(2).to_a.map { |p| calculate_true_range(p[0], p[1]) }.inject { |trs, tr| trs + ',' + tr }.to_f

            candle_stack = prices.map { |p| "#{p[:high]},#{p[:low]},#{p[:close]}" }.join(';')
            puts "#{symbol} #{candle_stack}"
            f.write("#{symbol}:#{candle_stack}\n")
          rescue
            puts "Skipping symbol #{symbol}"
          end
        end

        f.close
      end
      wl_file = File.join(Dir.pwd, 'run', 'atrs.txt')
      f = File.open(wl_file, 'r')
      lines = f.read().split("\n")
      f.close
      lines.each do |line|
        symbol, candle_stack = line.split(':')
        symbol_properties = SymbolDataStore.new(symbol)
        symbol_properties.candle_stack = candle_stack.split(';').map { |candle| c = Candle.new; c[:high], c[:low], c[:close] = candle.split(',').map(&:to_f); c }
        @watchlist.add(symbol_properties)
      end

      i = 1
      stream.run do |data|
        # for each stream record
        # 1. Skip it if the timestamp is not up to date.
        # 2. Calculate the current true range
        # 3. Calculate the average true range
        # 4. Process alert
        #   - if it meets the alert criteria, send it if it hasn't been alerted in the last 20 min

        next if data.columns.nil? || data.columns[:symbol].nil?
        next if data.columns[:last].nil? || data.columns[:volume].nil?
        next if data.columns[:symbol] != "KATE"
        #puts "#{i} + #{data.columns}"
        symbol = data.columns[:symbol].to_sym
        next if @watchlist[symbol].nil? # this wasn't on the watchlist so we haven't calculated an average true range for it

        # Need a time with this or its no good to us
        time = data.columns[:tradetime] || data.columns[:quotetime]
        next if time.nil?
        next if time < @watchlist[symbol].current_candle.time

        if calculate_time_bucket(time) > @watchlist[symbol].current_candle.time_bucket && data.columns[:last]
          #the time bucket on the currently received data is greater than the current candle; we have a new currentcandle
          new_candle = Candle.new
          new_candle.close = data.columns[:last]
          new_candle.high = data.columns[:last] # on a brand new candle, we don't have any range yet
          new_candle.low = data.columns[:last] # on a brand new candle, we don't have any range yet
          new_candle.volume = data.columns[:volume] if data.columns[:volume]
          new_candle.time = time

          @watchlist[symbol].replace_current_candle(new_candle)
        elsif calculate_time_bucket(time) == @watchlist[symbol].current_candle.time_bucket && data.columns[:last]
          #the time bucket on the currently received data is the same than the current candle; update the current candle
          # note that we ignore any instances where the timestamp on the new data is LESS than the current candle's time bucket
          current_candle = @watchlist[symbol].current_candle

          new_candle = Candle.new
          new_candle.close = data.columns[:last]
          new_candle.high = [data.columns[:last], current_candle.high].max
          new_candle.low = [data.columns[:last], current_candle.low].min
          new_candle.volume = data.columns[:volume] if data.columns[:volume]
          new_candle.time = time

          @watchlist[symbol].update_current_candle(new_candle)
        end

        do_alert(symbol, calculate_time_bucket(time)) if @watchlist[symbol].true_range > (@watchlist[symbol].average_true_range * 5)
        puts "#{i} + #{data.columns} + #{@watchlist[symbol].current_candle.time_bucket} #{@watchlist[symbol].true_range.round(4)} / #{(@watchlist[symbol].average_true_range * 5).round(4)}"
        i += 1
      end

    end

    private

    def do_alert(symbol, time)
      return if time < 945
      if time - @watchlist[symbol].alert_triggered_time > 100
        puts "Alert on #{symbol.to_s} at #{time}"
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