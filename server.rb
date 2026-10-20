require 'date'
require 'json'
require 'net/http'
require 'openssl'
require 'pathname'
require 'securerandom'
require 'time'
require 'timeout'
require 'uri'
require 'webrick'

def load_local_env
  env_path = Pathname.new(__dir__).join('.env')
  return unless env_path.file?

  env_path.each_line do |line|
    match = line.match(/\A\s*([A-Z][A-Z0-9_]*)\s*=\s*(.*?)\s*\z/)
    next unless match

    key = match[1]
    value = match[2].sub(/\A(['"])(.*)\1\z/, '\2')
    ENV[key] = value unless ENV.key?(key)
  end
end

load_local_env

ROOT = Pathname.new(__dir__).realpath
PORT = Integer(ENV.fetch('PORT', '8000'))
GROWW_API_KEY = ENV.fetch('GROWW_API_KEY', '').strip
GROWW_API_SECRET = ENV.fetch('GROWW_API_SECRET', '').strip
GROWW_TOTP_SECRET = ENV.fetch('GROWW_TOTP_SECRET', '').strip
GROWW_BASE_URL = 'https://api.groww.in/v1'.freeze
GROWW_TOKEN_URL = 'https://api.groww.in/v1/token/api/access'.freeze
SYMBOLS = %w[NIFTY SENSEX].freeze
SYMBOL_EXCHANGES = { 'NIFTY' => 'NSE', 'SENSEX' => 'BSE' }.freeze
STRIKE_PRICE_RANGES = { 'NIFTY' => 500.0, 'SENSEX' => 1000.0 }.freeze
NSE_HOLIDAY_URL = 'https://www.nseindia.com/api/holiday-master?type=trading'.freeze
NSE_HOLIDAY_SOURCE = 'https://www.nseindia.com/resources/exchange-communication-holidays'.freeze
OI_HISTORY_WINDOW_SECONDS = 15 * 60
OI_HISTORY_TOLERANCE_SECONDS = 5 * 60
OI_HISTORY_RETENTION_SECONDS = OI_HISTORY_WINDOW_SECONDS + OI_HISTORY_TOLERANCE_SECONDS + 5 * 60
TRADING_DATA_CACHE_SECONDS = 60
HOLIDAY_CACHE_SECONDS = 6 * 60 * 60
STRIKE_SCORE_WEIGHTS = {
  'premiumMomentum' => Float(ENV.fetch('OI_SCORE_WEIGHT_PREMIUM', '20')),
  'underlyingTrend' => Float(ENV.fetch('OI_SCORE_WEIGHT_TREND', '20')),
  'volumeLiquidity' => Float(ENV.fetch('OI_SCORE_WEIGHT_LIQUIDITY', '15')),
  'oiPositioning' => Float(ENV.fetch('OI_SCORE_WEIGHT_OI', '15')),
  'volatility' => Float(ENV.fetch('OI_SCORE_WEIGHT_VOLATILITY', '15')),
  'greeksSuitability' => Float(ENV.fetch('OI_SCORE_WEIGHT_GREEKS', '10')),
  'riskReward' => Float(ENV.fetch('OI_SCORE_WEIGHT_RISK_REWARD', '5'))
}.freeze
MIN_ABSOLUTE_DELTA = Float(ENV.fetch('OI_MIN_ABSOLUTE_DELTA', '0.45'))
MAX_ABSOLUTE_DELTA = Float(ENV.fetch('OI_MAX_ABSOLUTE_DELTA', '0.70'))
MAX_BID_ASK_SPREAD_PERCENT = Float(ENV.fetch('OI_MAX_BID_ASK_SPREAD_PERCENT', '2.0'))
RSI_BULLISH_THRESHOLD = Float(ENV.fetch('OI_RSI_BULLISH_THRESHOLD', '55'))
RSI_BEARISH_THRESHOLD = Float(ENV.fetch('OI_RSI_BEARISH_THRESHOLD', '45'))
MIN_CANDIDATE_SCORE = Float(ENV.fetch('OI_MIN_CANDIDATE_SCORE', '65'))
STRONG_CANDIDATE_SCORE = Float(ENV.fetch('OI_STRONG_CANDIDATE_SCORE', '80'))
TEST_PREVIEW_ENABLED = ENV['DASHBOARD_TEST_PREVIEW'] == '1'

unless (STRIKE_SCORE_WEIGHTS.values.sum - 100.0).abs < 0.001
  raise ArgumentError, 'OI score weight environment variables must total 100.'
end
if MIN_ABSOLUTE_DELTA.negative? || MAX_ABSOLUTE_DELTA > 1 ||
   MIN_ABSOLUTE_DELTA > MAX_ABSOLUTE_DELTA || MAX_BID_ASK_SPREAD_PERCENT.negative? ||
   RSI_BEARISH_THRESHOLD >= RSI_BULLISH_THRESHOLD ||
   MIN_CANDIDATE_SCORE.negative? || STRONG_CANDIDATE_SCORE > 100 ||
   MIN_CANDIDATE_SCORE > STRONG_CANDIDATE_SCORE
  raise ArgumentError, 'Invalid OI strategy threshold configuration.'
end

class FeedError < StandardError; end

@groww_access_token = nil
@groww_access_token_date = nil
@oi_history = []
@oi_history_lock = Mutex.new
@expiry_cache = {}
@expiry_cache_lock = Mutex.new
@trading_summary_cache = nil
@trading_summary_cache_at = nil
@trading_summary_lock = Mutex.new
@holiday_cache = nil
@holiday_cache_at = nil
@holiday_cache_lock = Mutex.new

def number(value)
  result = Float(value)
  result.finite? && result >= 0 ? result : nil
rescue ArgumentError, TypeError
  nil
end

def signed_number(value)
  result = Float(value)
  result.finite? ? result : nil
rescue ArgumentError, TypeError
  nil
end

def decode_base32(value)
  alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
  bits = value.upcase.delete('= ').each_char.map do |character|
    index = alphabet.index(character)
    raise FeedError, 'The TOTP secret is not valid Base32.' unless index

    index.to_s(2).rjust(5, '0')
  end.join
  bytes = bits.scan(/.{8}/).map { |byte| byte.to_i(2) }.pack('C*')
  raise FeedError, 'The TOTP secret is too short.' if bytes.empty?

  bytes
end

def generate_totp(secret, at: Time.now.to_i)
  key = decode_base32(secret)
  counter = [at / 30].pack('Q>')
  digest = OpenSSL::HMAC.digest('sha1', key, counter)
  offset = digest.getbyte(-1) & 0x0f
  code = digest.byteslice(offset, 4).unpack1('N') & 0x7fffffff
  (code % 1_000_000).to_s.rjust(6, '0')
end

def smartapi_public_ip
  configured = ENV.fetch('SMARTAPI_CLIENT_PUBLIC_IP', '').strip
  return configured unless configured.empty?
  return @smartapi_public_ip if @smartapi_public_ip

  uri = URI('https://api.ipify.org')
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 5) do |http|
    http.get(uri)
  end
  ip = response.body.to_s.strip
  return @smartapi_public_ip = ip if response.is_a?(Net::HTTPSuccess) && ip.match?(/\A(?:\d{1,3}\.){3}\d{1,3}\z/)

  raise FeedError, 'Could not determine the public IPv4 address required by SmartAPI. Set SMARTAPI_CLIENT_PUBLIC_IP in .env.'
rescue IOError, SystemCallError, SocketError, Timeout::Error
  raise FeedError, 'Could not determine the public IP required by SmartAPI. Set SMARTAPI_CLIENT_PUBLIC_IP in .env.'
end

def smartapi_request(path, payload, authenticated: true)
  @smartapi_lock.synchronize do
    if @smartapi_last_request_at
      wait = SMARTAPI_MARKET_REQUEST_INTERVAL - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @smartapi_last_request_at)
      sleep(wait) if wait.positive?
    end
    @smartapi_last_request_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    uri = URI("#{SMARTAPI_BASE_URL}#{path}")
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['Accept'] = 'application/json'
    request['X-PrivateKey'] = SMARTAPI_API_KEY
    request['X-UserType'] = 'USER'
    request['X-SourceID'] = 'WEB'
    request['X-ClientLocalIP'] = system_client_ip
    request['X-ClientPublicIP'] = smartapi_public_ip
    request['X-MACAddress'] = system_mac_address
    request['Authorization'] = "Bearer #{@smartapi_jwt}" if authenticated && @smartapi_jwt
    request.body = JSON.generate(payload)

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) do |http|
      http.request(request)
    end
    begin
      body = JSON.parse(response.body)
    rescue JSON::ParserError
      raise FeedError, "SmartAPI returned an unreadable response (HTTP #{response.code})."
    end
    unless response.is_a?(Net::HTTPSuccess) && body['status'] != false
      message = body['message'] || body['errorcode'] || "HTTP #{response.code}"
      raise FeedError, "SmartAPI request failed: #{message}"
    end

    body
  end
rescue IOError, SystemCallError, SocketError, Timeout::Error, URI::InvalidURIError
  raise FeedError, 'Could not connect to the SmartAPI service.'
end

def smartapi_login
  today = Time.now.getlocal('+05:30').to_date
  return if @smartapi_jwt && @smartapi_jwt_date == today

  @smartapi_jwt = nil
  response = smartapi_request(
    SMARTAPI_LOGIN_PATH,
    {
      'clientcode' => SMARTAPI_CLIENT_CODE,
      'password' => SMARTAPI_PIN,
      'totp' => generate_totp(SMARTAPI_TOTP_SECRET)
    },
    authenticated: false
  )
  token = response.dig('data', 'jwtToken')
  raise FeedError, 'SmartAPI login succeeded without returning a session token.' unless token

  @smartapi_jwt = token
  @smartapi_jwt_date = today
end

def groww_credentials_started?
  [GROWW_API_KEY, GROWW_API_SECRET, GROWW_TOTP_SECRET].any? { |value| !value.empty? }
end

def groww_credentials_missing
  missing = []
  missing << 'GROWW_API_KEY' if GROWW_API_KEY.empty?
  if GROWW_API_SECRET.empty? && GROWW_TOTP_SECRET.empty?
    missing << 'GROWW_API_SECRET or GROWW_TOTP_SECRET'
  end
  missing
end

def groww_headers(token)
  {
    'Accept' => 'application/json',
    'Content-Type' => 'application/json',
    'Authorization' => "Bearer #{token}",
    'X-Request-Id' => SecureRandom.uuid,
    'X-Client-Id' => 'growwapi',
    'X-Client-Platform' => 'growwapi-python-client',
    'X-Client-Platform-Version' => '1.5.0',
    'X-Api-Version' => '1.0'
  }
end

def parse_groww_response(response)
  begin
    body = JSON.parse(response.body)
  rescue JSON::ParserError
    raise FeedError, "Groww returned an unreadable response (HTTP #{response.code})."
  end
  raise FeedError, 'Groww returned an unexpected response format.' unless body.is_a?(Hash)

  unless response.is_a?(Net::HTTPSuccess) && body['status'] != 'FAILURE'
    detail = body.dig('error', 'message') || body.dig('error', 'displayMessage')
    detail ||= body['message'] if body['message'].is_a?(String)
    raise FeedError, "Groww API request failed: #{detail || "HTTP #{response.code}"}."
  end

  body.fetch('payload', body)
end

def groww_get(path, params, token)
  uri = URI("#{GROWW_BASE_URL}#{path}")
  uri.query = URI.encode_www_form(params)
  request = Net::HTTP::Get.new(uri)
  groww_headers(token).each { |key, value| request[key] = value }
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 25) do |http|
    http.request(request)
  end
  parse_groww_response(response)
rescue IOError, SystemCallError, SocketError, Timeout::Error, URI::InvalidURIError
  raise FeedError, 'Could not connect to the Groww API.'
end

def fetch_nse_holiday_data(now: Time.now)
  @holiday_cache_lock.synchronize do
    monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    if @holiday_cache && @holiday_cache_at && monotonic_now - @holiday_cache_at < HOLIDAY_CACHE_SECONDS
      return @holiday_cache
    end

    uri = URI(NSE_HOLIDAY_URL)
    request = Net::HTTP::Get.new(uri)
    request['Accept'] = 'application/json'
    request['User-Agent'] = 'Mozilla/5.0 (compatible; Live-OI-Strike-Analyzer/1.0)'
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) do |http|
      http.request(request)
    end
    raise FeedError, "NSE holiday calendar returned HTTP #{response.code}." unless response.is_a?(Net::HTTPSuccess)

    payload = JSON.parse(response.body)
    calendar = payload['CM']
    raise FeedError, 'NSE holiday calendar did not contain the cash-market calendar.' unless calendar.is_a?(Array)

    dates = calendar.each_with_object([]) do |item, result|
      next unless item.is_a?(Hash)

      result << Date.strptime(item['tradingDate'].to_s, '%d-%b-%Y').iso8601
    rescue Date::Error
      next
    end
    raise FeedError, 'NSE holiday calendar contained no valid trading dates.' if dates.empty?

    holidays = {
      'dates' => dates.uniq.sort,
      'entries' => calendar.each_with_object([]) do |item, result|
        next unless item.is_a?(Hash)

        date = Date.strptime(item['tradingDate'].to_s, '%d-%b-%Y')
        result << {
          'date' => date.iso8601,
          'day' => item['weekDay'],
          'description' => item['description']
        }
      rescue Date::Error
        next
      end.sort_by { |item| item['date'] },
      'source' => NSE_HOLIDAY_SOURCE,
      'sourceName' => 'NSE India official trading holiday calendar',
      'updatedAt' => Time.now.utc.iso8601,
      'status' => 'live',
      'scope' => 'NSE cash-market calendar; used as the shared NIFTY/SENSEX closure calendar.'
    }
    @holiday_cache = holidays
    @holiday_cache_at = monotonic_now
    holidays
  rescue FeedError, JSON::ParserError, IOError, SystemCallError, SocketError, Timeout::Error, URI::InvalidURIError => error
    if @holiday_cache
      @holiday_cache.merge(
        'status' => 'stale',
        'warning' => "Could not refresh NSE's holiday calendar: #{error.message}"
      )
    else
      {
        'dates' => [],
        'entries' => [],
        'source' => NSE_HOLIDAY_SOURCE,
        'sourceName' => 'NSE India official trading holiday calendar',
        'updatedAt' => nil,
        'status' => 'unavailable',
        'warning' => "Could not load NSE's holiday calendar: #{error.message}"
      }
    end
  end
end

def parse_trade_time(value)
  Time.iso8601(value.to_s)
rescue ArgumentError
  nil
end

def nse_trading_session?(time)
  ist_time = time.getlocal('+05:30')
  return false unless %w[Mon Tue Wed Thu Fri].include?(ist_time.strftime('%a'))

  calendar = @holiday_cache
  return false unless calendar && %w[live stale].include?(calendar['status'])

  !calendar.fetch('dates', []).include?(ist_time.to_date.iso8601)
end

def trade_cycles(trades)
  cycles = []
  positions = {}
  trades.sort_by { |trade| parse_trade_time(trade['trade_date_time'] || trade['time']) || Time.at(0) }.each do |trade|
    symbol = (trade['trading_symbol'] || trade['symbol']).to_s
    transaction = (trade['transaction_type'] || trade['side']).to_s.upcase
    quantity = number(trade['quantity'])&.to_i
    price = number(trade['price'])
    time = parse_trade_time(trade['trade_date_time'] || trade['time'])
    fill_id = trade['groww_trade_id'] || trade['id']
    direction = transaction == 'BUY' ? 1 : (transaction == 'SELL' ? -1 : 0)
    next if symbol.empty? || direction.zero? || !quantity&.positive? || !price&.positive? || !time

    position = positions[symbol] ||= { 'quantity' => 0, 'cycle' => nil }
    remaining = quantity
    if position['quantity'].zero? || position['quantity'] * direction > 0
      position['cycle'] ||= {
        'symbol' => symbol,
        'side' => direction.positive? ? 'LONG' : 'SHORT',
        'entryValue' => 0.0,
        'entryQuantity' => 0,
        'exitValue' => 0.0,
        'quantity' => 0,
        'realizedPnl' => 0.0,
        'entryTime' => time,
        'fillIds' => []
      }
      cycle = position['cycle']
      cycle['entryValue'] += price * remaining
      cycle['entryQuantity'] += remaining
      cycle['fillIds'] << fill_id if fill_id
      position['quantity'] += direction * remaining
      next
    end

    matched = [position['quantity'].abs, remaining].min
    cycle = position['cycle']
    cycle['exitValue'] += price * matched
    cycle['quantity'] += matched
    cycle['realizedPnl'] += (price - cycle['entryValue'] / cycle['entryQuantity']) * matched *
      (position['quantity'].positive? ? 1 : -1)
    cycle['fillIds'] << fill_id if fill_id
    position['quantity'] += direction * matched
    remaining -= matched
    if position['quantity'].zero?
      cycles << {
        'id' => cycle['fillIds'].join(':'),
        'symbol' => symbol,
        'side' => cycle['side'],
        'quantity' => cycle['quantity'],
        'entryPrice' => cycle['entryValue'] / cycle['entryQuantity'],
        'exitPrice' => cycle['exitValue'] / cycle['quantity'],
        'realizedPnl' => cycle['realizedPnl'].round(2),
        'entryTime' => cycle['entryTime'].utc.iso8601,
        'exitTime' => time.utc.iso8601
      }
      position['cycle'] = nil
    end
    next unless remaining.positive?

    position['cycle'] = {
      'symbol' => symbol,
      'side' => direction.positive? ? 'LONG' : 'SHORT',
      'entryValue' => price * remaining,
      'entryQuantity' => remaining,
      'exitValue' => 0.0,
      'quantity' => 0,
      'realizedPnl' => 0.0,
      'entryTime' => time,
      'fillIds' => [fill_id].compact
    }
    position['quantity'] = direction * remaining
  end
  cycles
end

def fetch_groww_trading_summary(now: Time.now)
  trading_date = now.getlocal('+05:30').to_date.iso8601
  @trading_summary_lock.synchronize do
    monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    if @trading_summary_cache && @trading_summary_cache['date'] == trading_date &&
       @trading_summary_cache_at && monotonic_now - @trading_summary_cache_at < TRADING_DATA_CACHE_SECONDS
      return @trading_summary_cache
    end

    token = groww_access_token
    orders = []
    20.times do |page|
      payload = groww_get('/order/list', { 'segment' => 'FNO', 'page' => page, 'page_size' => 100 }, token)
      page_orders = payload['order_list']
      raise FeedError, 'Groww order list response is missing order_list.' unless page_orders.is_a?(Array)

      orders.concat(page_orders)
      break if page_orders.length < 100
      raise FeedError, 'Groww order list exceeds the supported pagination limit.' if page == 19
    end

    fills = []
    orders.each do |order|
      next unless order.is_a?(Hash) && (number(order['filled_quantity']) || 0).positive?

      order_id = order['groww_order_id'].to_s
      next unless order_id.match?(/\A[A-Za-z0-9_-]+\z/)

      20.times do |page|
        payload = groww_get(
          "/order/trades/#{order_id}",
          { 'segment' => 'FNO', 'page' => page, 'page_size' => 50 },
          token
        )
        page_trades = payload['trade_list']
        raise FeedError, "Groww trade response for order #{order_id} is missing trade_list." unless page_trades.is_a?(Array)

        page_trades.each do |trade|
          next unless trade.is_a?(Hash)
          next unless %w[COMPLETED EXECUTED].include?(trade['trade_status'].to_s.upcase)
          next unless trade['segment'].to_s.upcase == 'FNO'
          next unless parse_trade_time(trade['trade_date_time'])&.getlocal('+05:30')&.to_date&.iso8601 == trading_date

          fills << {
            'id' => trade['groww_trade_id'],
            'orderId' => trade['groww_order_id'] || order_id,
            'symbol' => trade['trading_symbol'].to_s.empty? ? order['trading_symbol'] : trade['trading_symbol'],
            'side' => trade['transaction_type'],
            'quantity' => number(trade['quantity'])&.to_i,
            'price' => number(trade['price']),
            'time' => trade['trade_date_time'],
            'product' => trade['product'],
            'exchange' => trade['exchange'] || order['exchange']
          }
        end
        break if page_trades.length < 50
        raise FeedError, "Groww trades for order #{order_id} exceed the supported pagination limit." if page == 19
      end
    end

    positions_payload = groww_get('/positions/user', { 'segment' => 'FNO' }, token)
    positions = positions_payload['positions']
    raise FeedError, 'Groww F&O positions response is missing positions.' unless positions.is_a?(Array)

    normalized_positions = positions.each_with_object([]) do |position, result|
      next unless position.is_a?(Hash)

      result << {
        'symbol' => position['trading_symbol'],
        'exchange' => position['exchange'],
        'product' => position['product'],
        'quantity' => number(position['quantity'])&.to_i,
        'realizedPnl' => signed_number(position['realised_pnl'])
      }
    end
    summary = {
      'date' => trading_date,
      'updatedAt' => Time.now.utc.iso8601,
      'source' => 'groww',
      'orders' => orders.length,
      'fills' => fills,
      'fillCount' => fills.length,
      'closedCycles' => trade_cycles(fills),
      'realizedPnl' => normalized_positions.sum { |position| position['realizedPnl'] || 0 },
      'positions' => normalized_positions
    }
    @trading_summary_cache = summary
    @trading_summary_cache_at = monotonic_now
    summary
  end
end

def groww_access_token
  today = Time.now.getlocal('+05:30').to_date
  return @groww_access_token if @groww_access_token && @groww_access_token_date == today
  if !GROWW_API_SECRET.empty? && !GROWW_TOTP_SECRET.empty?
    raise FeedError, 'Set only one of GROWW_API_SECRET or GROWW_TOTP_SECRET in .env.'
  end

  timestamp = Time.now.to_i
  payload = if !GROWW_TOTP_SECRET.empty?
              { 'key_type' => 'totp', 'totp' => generate_totp(GROWW_TOTP_SECRET) }
            else
              checksum = OpenSSL::Digest::SHA256.hexdigest("#{GROWW_API_SECRET}#{timestamp}")
              { 'key_type' => 'approval', 'checksum' => checksum, 'timestamp' => timestamp }
            end
  uri = URI(GROWW_TOKEN_URL)
  request = Net::HTTP::Post.new(uri)
  groww_headers(GROWW_API_KEY).each { |key, value| request[key] = value }
  request.body = JSON.generate(payload)
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) do |http|
    http.request(request)
  end
  body = parse_groww_response(response)
  token = body['token']
  raise FeedError, 'Groww authentication response did not include an access token.' unless token.is_a?(String) && !token.empty?

  @groww_access_token = token
  @groww_access_token_date = today
  token
rescue IOError, SystemCallError, SocketError, Timeout::Error, URI::InvalidURIError
  raise FeedError, 'Could not connect to the Groww authentication service.'
end

def groww_expiry_dates(response)
  dates = []
  visit = lambda do |value|
    case value
    when Hash
      value.each_value { |item| visit.call(item) }
    when Array
      value.each { |item| visit.call(item) }
    when String
      dates << Date.iso8601(value) if value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    end
  end
  visit.call(response)
  dates.uniq.sort
rescue Date::Error
  raise FeedError, 'Groww returned an invalid option expiry date.'
end

def groww_available_expiries(token, symbol, exchange, today)
  cache_key = [today.iso8601, symbol, exchange]
  @expiry_cache_lock.synchronize do
    cached = @expiry_cache[cache_key]
    return cached if cached

    dates = [today.year, today.year + 1].flat_map do |year|
      response = groww_get(
        '/historical/expiries',
        { 'exchange' => exchange, 'underlying_symbol' => symbol, 'year' => year },
        token
      )
      groww_expiry_dates(response)
    end.select { |date| date >= today }.uniq.sort
    raise FeedError, "Groww returned no upcoming expiry for #{symbol}." if dates.empty?

    @expiry_cache.delete_if { |key, _value| key[0] != today.iso8601 }
    @expiry_cache[cache_key] = dates
  end
end

def selected_expiry_for(symbol, requested_expiries, available_expiries)
  requested = requested_expiries[symbol]
  return available_expiries.first if requested.nil? || requested.empty?

  expiry = Date.iso8601(requested)
  unless available_expiries.include?(expiry)
    raise FeedError, "Selected expiry #{requested} is not available for #{symbol}."
  end
  expiry
rescue Date::Error
  raise FeedError, "Invalid expiry selection for #{symbol}."
end

def fetch_groww_index_data(token, symbol, exchange, today, requested_expiries = {})
  available_expiries = groww_available_expiries(token, symbol, exchange, today)
  expiry = selected_expiry_for(symbol, requested_expiries, available_expiries)
  chain = groww_get(
    "/option-chain/exchange/#{exchange}/underlying/#{URI.encode_www_form_component(symbol)}",
    { 'expiry_date' => expiry.iso8601 },
    token
  )
  strikes = chain['strikes']
  raise FeedError, "Groww option chain for #{symbol} is missing strike data." unless strikes.is_a?(Hash)

  best = { 'call' => nil, 'put' => nil }
  contracts = {}
  total_oi = { 'call' => 0, 'put' => 0 }
  strikes.each do |strike_text, sides|
    next unless sides.is_a?(Hash)

    strike = number(strike_text)
    next unless strike && strike.positive?
    { 'CE' => 'call', 'PE' => 'put' }.each do |side_key, side_name|
      contract = sides[side_key]
      next unless contract.is_a?(Hash)

      oi = number(contract['open_interest'])
      next unless oi
      volume = number(contract['volume'])
      ltp = number(contract['ltp'])
      greeks = contract['greeks'].is_a?(Hash) ? contract['greeks'] : contract
      contract_record = {
        'oi' => oi.to_i,
        'ltp' => ltp,
        'volume' => volume&.to_i,
        'tradingSymbol' => contract['trading_symbol'],
        'delta' => signed_number(greeks['delta']),
        'gamma' => signed_number(greeks['gamma']),
        'theta' => signed_number(greeks['theta']),
        'vega' => signed_number(greeks['vega']),
        'iv' => number(greeks['iv'] || contract['implied_volatility']),
        'oiDayChange' => signed_number(contract['oi_day_change']),
        'previousOi' => number(contract['previous_open_interest']),
        'lotSize' => number(contract['lot_size'] || contract['lot_size_quantity'])&.to_i
      }
      contracts["#{expiry.iso8601}|#{strike}|#{side_key}"] = contract_record
      total_oi[side_name] += oi
      candidate = { 'strike' => strike, 'oi' => oi.to_i }
      current = best[side_name]
      best[side_name] = candidate if current.nil? || candidate['oi'] > current['oi']
    end
  end
  unless best['call'] && best['put']
    raise FeedError, "Groww returned no call or put OI for #{symbol} at expiry #{expiry.iso8601}."
  end

  {
    'symbol' => symbol,
    'expiry' => expiry.strftime('%d %b %Y'),
    'expiryDate' => expiry.iso8601,
    'availableExpiries' => available_expiries.map(&:iso8601),
    'spotPrice' => number(chain['underlying_ltp']),
    'pcr' => total_oi['call'].positive? ? total_oi['put'].to_f / total_oi['call'] : nil,
    'call' => best['call'],
    'put' => best['put'],
    'contracts' => contracts
  }
end

def fetch_groww_index_candles(token, symbol, exchange, today)
  groww_symbols = {
    'NIFTY' => 'NSE-NIFTY',
    'SENSEX' => 'BSE-SENSEX'
  }
  now = Time.now.getlocal('+05:30')
  first_day = today - 14
  start_time = Time.new(first_day.year, first_day.month, first_day.day, 9, 15, 0, '+05:30')
  payload = groww_get(
    '/historical/candle/range',
    {
      'exchange' => exchange,
      'segment' => 'CASH',
      'trading_symbol' => groww_symbols.fetch(symbol),
      'start_time' => start_time.strftime('%Y-%m-%d %H:%M:%S'),
      'end_time' => now.strftime('%Y-%m-%d %H:%M:%S'),
      'interval_in_minutes' => 5
    },
    token
  )
  rows = payload.is_a?(Hash) ? payload['candles'] : nil
  raise FeedError, "Groww historical-candle response for #{symbol} is missing candles." unless rows.is_a?(Array)

  candles = rows.each_with_object([]) do |row, result|
    next unless row.is_a?(Array) && row.length >= 5

    time = parse_candle_time(row[0])
    next unless time && time + 5 * 60 <= now
    open_price, high, low, close = row[1, 4].map { |value| number(value) }
    next unless open_price&.positive? && high && low && close&.positive?
    next unless high >= [open_price, close, low].max && low <= [open_price, close].min

    result << {
      'time' => time,
      'open' => open_price,
      'high' => high,
      'low' => low,
      'close' => close,
      'volume' => number(row[5])
    }
  end
  candles.uniq { |candle| candle['time'].to_i }.sort_by { |candle| candle['time'] }
end

def parse_candle_time(value)
  return Time.at(Float(value)).getlocal('+05:30') if value.is_a?(Numeric) || value.to_s.match?(/\A\d+(?:\.\d+)?\z/)

  text = value.to_s
  return nil unless text.match?(/\A\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}/)

  Time.iso8601(text.match?(/[zZ]|[+-]\d{2}:?\d{2}\z/) ? text : "#{text}+05:30").getlocal('+05:30')
rescue ArgumentError, TypeError, RangeError
  nil
end

def exponential_moving_average(values, period)
  return [] if values.length < period

  initial = values.first(period).sum / period.to_f
  result = Array.new(period - 1)
  result << initial
  smoothing = 2.0 / (period + 1)
  values.drop(period).each do |value|
    initial = (value - initial) * smoothing + initial
    result << initial
  end
  result
end

def relative_strength_index(values, period = 14)
  return nil if values.length <= period

  changes = values.each_cons(2).map { |previous, current| current - previous }
  gains = changes.first(period).map { |change| [change, 0].max }
  losses = changes.first(period).map { |change| [-change, 0].max }
  average_gain = gains.sum / period.to_f
  average_loss = losses.sum / period.to_f
  changes.drop(period).each do |change|
    average_gain = (average_gain * (period - 1) + [change, 0].max) / period
    average_loss = (average_loss * (period - 1) + [-change, 0].max) / period
  end
  return 100.0 if average_loss.zero? && average_gain.positive?
  return 50.0 if average_loss.zero?

  100.0 - (100.0 / (1.0 + average_gain / average_loss))
end

def true_ranges(candles)
  candles.each_with_index.map do |candle, index|
    previous_close = index.positive? ? candles[index - 1]['close'] : candle['close']
    [
      candle['high'] - candle['low'],
      (candle['high'] - previous_close).abs,
      (candle['low'] - previous_close).abs
    ].max
  end
end

def average_directional_index(candles, period = 14)
  return nil if candles.length <= period * 2

  plus_moves = []
  minus_moves = []
  ranges = []
  candles.each_cons(2) do |previous, current|
    up = current['high'] - previous['high']
    down = previous['low'] - current['low']
    plus_moves << (up > down && up.positive? ? up : 0.0)
    minus_moves << (down > up && down.positive? ? down : 0.0)
    ranges << [
      current['high'] - current['low'],
      (current['high'] - previous['close']).abs,
      (current['low'] - previous['close']).abs
    ].max
  end
  plus_sum = plus_moves.first(period).sum
  minus_sum = minus_moves.first(period).sum
  range_sum = ranges.first(period).sum
  dx_values = []
  (period - 1...plus_moves.length).each do |index|
    if index >= period
      plus_sum = plus_sum - plus_sum / period + plus_moves[index]
      minus_sum = minus_sum - minus_sum / period + minus_moves[index]
      range_sum = range_sum - range_sum / period + ranges[index]
    end
    next unless range_sum.positive?

    plus_di = 100.0 * plus_sum / range_sum
    minus_di = 100.0 * minus_sum / range_sum
    denominator = plus_di + minus_di
    dx_values << (denominator.positive? ? 100.0 * (plus_di - minus_di).abs / denominator : 0.0)
  end
  return nil if dx_values.length < period

  adx = dx_values.first(period).sum / period
  dx_values.drop(period).each { |value| adx = (adx * (period - 1) + value) / period }
  { 'adx' => adx, 'plusDi' => 100.0 * plus_sum / range_sum, 'minusDi' => 100.0 * minus_sum / range_sum }
end

def aggregate_candles(candles, interval_seconds)
  candles.group_by { |candle| candle['time'].to_i / interval_seconds }.each_with_object([]) do |(bucket, items), result|
    sorted = items.sort_by { |candle| candle['time'] }
    expected_count = interval_seconds / (5 * 60)
    next unless sorted.length == expected_count
    next unless sorted.each_cons(2).all? { |left, right| right['time'] - left['time'] == 5 * 60 }

    result << {
      'time' => Time.at(bucket * interval_seconds).getlocal('+05:30'),
      'open' => sorted.first['open'],
      'high' => sorted.map { |candle| candle['high'] }.max,
      'low' => sorted.map { |candle| candle['low'] }.min,
      'close' => sorted.last['close'],
      'volume' => sorted.all? { |candle| candle['volume'] } ? sorted.sum { |candle| candle['volume'] } : nil
    }
  end.sort_by { |candle| candle['time'] }
end

def candle_indicators(candles, vwap_candles: candles)
  closes = candles.map { |candle| candle['close'] }
  ema9 = exponential_moving_average(closes, 9)
  ema20 = exponential_moving_average(closes, 20)
  ema50 = exponential_moving_average(closes, 50)
  macd_values = if closes.length >= 26
                  short = exponential_moving_average(closes, 12)
                  long = exponential_moving_average(closes, 26)
                  short.zip(long).map { |left, right| left && right ? left - right : nil }.compact
                else
                  []
                end
  macd_signal = exponential_moving_average(macd_values, 9)
  ranges = true_ranges(candles)
  recent_ranges = ranges.last(14)
  rsi_values = closes.each_index.map do |index|
    relative_strength_index(closes[0..index], 14)
  end
  volumes_available = vwap_candles.all? { |candle| candle['volume'] }
  vwap = if volumes_available && vwap_candles.sum { |candle| candle['volume'] }.positive?
           total_volume = vwap_candles.sum { |candle| candle['volume'] }
           vwap_candles.sum do |candle|
             ((candle['high'] + candle['low'] + candle['close']) / 3.0) * candle['volume']
           end / total_volume
         end
  bands = if closes.length >= 20
            window = closes.last(20)
            mean = window.sum / 20.0
            deviation = Math.sqrt(window.sum { |value| (value - mean)**2 } / 20.0)
            { 'upper' => mean + 2 * deviation, 'middle' => mean, 'lower' => mean - 2 * deviation,
              'widthPercent' => mean.positive? ? 400 * deviation / mean : nil }
          end
  macd = macd_values.last
  signal = macd_signal.last
  {
    'close' => closes.last,
    'ema9' => ema9.last,
    'ema20' => ema20.last,
    'ema50' => ema50.last,
    'sma20' => closes.length >= 20 ? closes.last(20).sum / 20.0 : nil,
    'sma50' => closes.length >= 50 ? closes.last(50).sum / 50.0 : nil,
    'vwap' => vwap,
    'rsi14' => rsi_values.last,
    'rsi14Previous' => rsi_values[-2],
    'macd' => macd,
    'macdSignal' => signal,
    'macdHistogram' => macd && signal ? macd - signal : nil,
    'atr14' => recent_ranges.length == 14 ? recent_ranges.sum / 14.0 : nil,
    'adx14' => average_directional_index(candles),
    'bollinger20' => bands
  }
end

def market_indicators(candles, now: Time.now)
  now_ist = now.getlocal('+05:30')
  today_candles = candles.select { |candle| candle['time'].getlocal('+05:30').to_date == now_ist.to_date }
  fifteen_minute_candles = aggregate_candles(candles, 15 * 60)
  fifteen_today = fifteen_minute_candles.select do |candle|
    candle['time'].getlocal('+05:30').to_date == now_ist.to_date
  end
  opening_range = today_candles.select do |candle|
    time = candle['time'].getlocal('+05:30')
    time.hour == 9 && time.min >= 15 && time.min < 30
  end
  prior_dates = candles.map { |candle| candle['time'].getlocal('+05:30').to_date }.uniq.sort
  prior_day = prior_dates.select { |date| date < now_ist.to_date }.last
  prior_candles = prior_day ? candles.select { |candle| candle['time'].getlocal('+05:30').to_date == prior_day } : []
  recent = today_candles[0...-1].last(3)
  {
    'fiveMinute' => candle_indicators(candles, vwap_candles: today_candles),
    'fifteenMinute' => candle_indicators(fifteen_minute_candles, vwap_candles: fifteen_today),
    'openingRange' => opening_range.length == 3 ? {
      'high' => opening_range.map { |candle| candle['high'] }.max,
      'low' => opening_range.map { |candle| candle['low'] }.min
    } : nil,
    'previousDay' => prior_candles.empty? ? nil : {
      'high' => prior_candles.map { |candle| candle['high'] }.max,
      'low' => prior_candles.map { |candle| candle['low'] }.min,
      'close' => prior_candles.last['close']
    },
    'recentSupport' => recent.empty? ? nil : recent.map { |candle| candle['low'] }.min,
    'recentResistance' => recent.empty? ? nil : recent.map { |candle| candle['high'] }.max,
    'completedCandles' => candles.length,
    'latestCandleTime' => candles.last && candles.last['time'].utc.iso8601
  }
end

def groww_supertrend(candles, period: 10, multiplier: 3)
  return nil if candles.length < period

  true_ranges = candles.each_with_index.map do |candle, index|
    previous_close = index.positive? ? candles[index - 1]['close'] : candle['close']
    [
      candle['high'] - candle['low'],
      (candle['high'] - previous_close).abs,
      (candle['low'] - previous_close).abs
    ].max
  end
  start_index = period - 1
  atr = true_ranges[start_index - period + 1..start_index].sum / period
  middle = (candles[start_index]['high'] + candles[start_index]['low']) / 2.0
  final_upper = middle + multiplier * atr
  final_lower = middle - multiplier * atr
  direction = candles[start_index]['close'] >= middle ? 'bullish' : 'bearish'

  (start_index + 1...candles.length).each do |index|
    atr = true_ranges[index - period + 1..index].sum / period
    candle = candles[index]
    middle = (candle['high'] + candle['low']) / 2.0
    basic_upper = middle + multiplier * atr
    basic_lower = middle - multiplier * atr
    previous_close = candles[index - 1]['close']
    final_upper = if basic_upper < final_upper || previous_close > final_upper
                    basic_upper
                  else
                    final_upper
                  end
    final_lower = if basic_lower > final_lower || previous_close < final_lower
                    basic_lower
                  else
                    final_lower
                  end
    direction = if direction == 'bearish' && candle['close'] > final_upper
                  'bullish'
                elsif direction == 'bullish' && candle['close'] < final_lower
                  'bearish'
                else
                  direction
                end
  end

  {
    'direction' => direction,
    'level' => direction == 'bullish' ? final_lower : final_upper
  }
end

def percentile_rank(value, peer_values)
  values = peer_values.compact.sort
  return nil if value.nil? || values.empty?
  return 0.5 if values.length == 1

  lower = values.count { |peer| peer < value }
  equal = values.count { |peer| peer == value }
  (lower + (equal - 1) / 2.0) / (values.length - 1).to_f
end

def directional_match(value, side_name, comparison = :positive)
  return nil if value.nil? || value.zero?

  side_name == 'call' ? value.positive? : value.negative?
end

def candidate_trend_tests(market_context, side_name)
  direction = side_name == 'call' ? 'bullish' : 'bearish'
  positive = side_name == 'call'
  five = market_context.dig('indicators', 'fiveMinute') || {}
  fifteen = market_context.dig('indicators', 'fifteenMinute') || {}
  opening = market_context.dig('indicators', 'openingRange')
  recent_resistance = market_context.dig('indicators', 'recentResistance')
  recent_support = market_context.dig('indicators', 'recentSupport')
  [
    ['15-min EMA20/50 alignment', five_or_fifteen_alignment(fifteen, positive)],
    ['15-min close vs VWAP', compared?(fifteen['close'], fifteen['vwap'], positive)],
    ['15-min RSI(14) above 55 / below 45 and rising / falling',
     rsi_direction_match(fifteen, positive)],
    ['5-min close vs VWAP', compared?(five['close'], five['vwap'], positive)],
    ['5-min EMA20/50 alignment', five_or_fifteen_alignment(five, positive)],
    ['5-min RSI(14) above 55 / below 45 and rising / falling', rsi_direction_match(five, positive)],
    ['5-min Supertrend', market_context.dig('supertrend', 'direction') == direction],
    ['15-min index price change', directional_match(market_context['spotChange'], side_name)],
    ['Opening-range or recent swing break',
     opening_or_swing_break(market_context, positive, opening, recent_resistance, recent_support)]
  ]
end

def compared?(left, right, positive)
  return nil if left.nil? || right.nil?

  positive ? left > right : left < right
end

def five_or_fifteen_alignment(indicators, positive)
  return nil unless indicators['ema20'] && indicators['ema50']

  positive ? indicators['ema20'] > indicators['ema50'] : indicators['ema20'] < indicators['ema50']
end

def rsi_direction_match(indicators, positive)
  rsi = indicators['rsi14']
  previous = indicators['rsi14Previous']
  return nil unless rsi && previous

  positive ? rsi > RSI_BULLISH_THRESHOLD && rsi > previous :
    rsi < RSI_BEARISH_THRESHOLD && rsi < previous
end

def opening_or_swing_break(market_context, positive, opening, resistance, support)
  close = market_context.dig('indicators', 'fiveMinute', 'close')
  return nil unless close

  thresholds = []
  thresholds << (positive ? opening&.dig('high') : opening&.dig('low'))
  thresholds << (positive ? resistance : support)
  thresholds.compact.any? { |level| positive ? close > level : close < level }
end

def classify_market_regime(indicators)
  five = indicators['fiveMinute'] || {}
  fifteen = indicators['fifteenMinute'] || {}
  adx = fifteen.dig('adx14', 'adx')
  bullish = five_or_fifteen_alignment(five, true) &&
    five_or_fifteen_alignment(fifteen, true) &&
    compared?(fifteen['close'], fifteen['vwap'], true) &&
    compared?(five['close'], five['vwap'], true)
  bearish = five_or_fifteen_alignment(five, false) &&
    five_or_fifteen_alignment(fifteen, false) &&
    compared?(fifteen['close'], fifteen['vwap'], false) &&
    compared?(five['close'], five['vwap'], false)
  return 'bullish' if bullish && adx && adx >= 20
  return 'bearish' if bearish && adx && adx >= 20
  return 'sideways' if adx && adx < 20

  'uncertain'
end

def score_trade_candidate(candidate, peers, side_name, market_context)
  components = {}
  score = 0.0
  available_weight = 0.0
  add_component = lambda do |name, weight, points, detail, available = true, component_available_weight = nil|
    components[name] = {
      'score' => points.round(2),
      'weight' => weight,
      'available' => available,
      'availableWeight' => component_available_weight || (available ? weight : 0),
      'detail' => detail
    }
    score += points if available
    available_weight += component_available_weight || (available ? weight : 0)
  end

  premium_change = candidate['premiumChangePercent']
  premium_peers = peers.map { |peer| peer['premiumChangePercent'] }.compact
  premium_rank = percentile_rank(premium_change, premium_peers)
  add_component.call(
    'premiumMomentum', STRIKE_SCORE_WEIGHTS['premiumMomentum'],
    premium_change && premium_rank && premium_change.positive? ?
      STRIKE_SCORE_WEIGHTS['premiumMomentum'] * premium_rank : 0,
    premium_change.nil? ? '15-minute premium history unavailable' : "#{premium_change.round(2)}% over 15 minutes",
    !premium_change.nil?
  )

  trend_tests = candidate_trend_tests(market_context, side_name)
  known_tests = trend_tests.reject { |_label, value| value.nil? }
  trend_points = known_tests.empty? ? 0 :
    STRIKE_SCORE_WEIGHTS['underlyingTrend'] * known_tests.count { |_label, value| value } / trend_tests.length.to_f
  add_component.call(
    'underlyingTrend', STRIKE_SCORE_WEIGHTS['underlyingTrend'], trend_points,
    "#{known_tests.count { |_label, value| value }}/#{trend_tests.length} checks aligned; #{trend_tests.count { |_label, value| value.nil? }} unavailable",
    !known_tests.empty?, STRIKE_SCORE_WEIGHTS['underlyingTrend'] * known_tests.length / trend_tests.length.to_f
  )

  volume_rank = percentile_rank(candidate['volume'], peers.map { |peer| peer['volume'] })
  spread_rank = percentile_rank(
    candidate['bidAskSpreadPercent'] && -candidate['bidAskSpreadPercent'],
    peers.map { |peer| peer['bidAskSpreadPercent'] && -peer['bidAskSpreadPercent'] }
  )
  liquidity_points = 0.0
  liquidity_points += 7.5 * volume_rank if volume_rank && candidate['volume'].positive?
  liquidity_points += 7.5 * spread_rank if spread_rank
  liquidity_available_weight = (candidate['volume']&.positive? ? 7.5 : 0) + (spread_rank ? 7.5 : 0)
  add_component.call(
    'volumeLiquidity', STRIKE_SCORE_WEIGHTS['volumeLiquidity'], liquidity_points,
    [
      candidate['volume']&.positive? ? "chain volume rank #{(volume_rank * 100).round}%" : 'no traded volume',
      candidate['bidAskSpreadPercent'] ? "spread #{candidate['bidAskSpreadPercent'].round(2)}%" : 'bid/ask unavailable'
    ].join('; '),
    !volume_rank.nil? || !spread_rank.nil?, liquidity_available_weight
  )

  oi_change = candidate['oiChangePercent']
  oi_rank = percentile_rank(oi_change, peers.map { |peer| peer['oiChangePercent'] })
  oi_consistent = candidate['oiChange'] && premium_change && candidate['oiChange'].positive? &&
    premium_change.positive? && market_context['spotChange'] &&
    directional_match(market_context['spotChange'], side_name)
  oi_points = if oi_consistent && oi_rank
                STRIKE_SCORE_WEIGHTS['oiPositioning'] * oi_rank
              elsif candidate['oiChange'] && candidate['oiChange'].negative? &&
                    premium_change&.positive? && market_context['spotChange'] &&
                    directional_match(market_context['spotChange'], side_name)
                STRIKE_SCORE_WEIGHTS['oiPositioning'] * 0.5
              else
                0
              end
  add_component.call(
    'oiPositioning', STRIKE_SCORE_WEIGHTS['oiPositioning'], oi_points,
    candidate['oiHypothesis'] || '15-minute OI snapshot unavailable; neutral',
    !candidate['oiChange'].nil?
  )

  iv_change = candidate['ivChange']
  iv_rank = percentile_rank(iv_change, peers.map { |peer| peer['ivChange'] })
  volatility_points = iv_change && iv_rank && iv_change.positive? && premium_change&.positive? ?
    STRIKE_SCORE_WEIGHTS['volatility'] * iv_rank : 0
  add_component.call(
    'volatility', STRIKE_SCORE_WEIGHTS['volatility'], volatility_points,
    candidate['iv'].nil? ? 'Groww IV unavailable' :
      (iv_change.nil? ? "IV #{candidate['iv'].round(2)}; historical IV change unavailable" :
        "IV #{candidate['iv'].round(2)}; change #{iv_change.round(2)}"),
    !iv_change.nil?
  )

  absolute_delta = candidate['delta']&.abs
  delta_valid = absolute_delta && absolute_delta.between?(MIN_ABSOLUTE_DELTA, MAX_ABSOLUTE_DELTA)
  delta_score = if delta_valid
                  6.0 * [1.0 - ((absolute_delta - 0.575).abs / 0.125), 0.0].max
                else
                  0
                end
  theta_ratio = candidate['theta'] && candidate['ltp']&.positive? ?
    candidate['theta'].abs / candidate['ltp'] : nil
  theta_rank = percentile_rank(theta_ratio && -theta_ratio, peers.map do |peer|
    peer['theta'] && peer['ltp']&.positive? ? -(peer['theta'].abs / peer['ltp']) : nil
  end)
  greek_available = !absolute_delta.nil?
  delta_score += 4.0 * theta_rank if theta_rank
  add_component.call(
    'greeksSuitability', STRIKE_SCORE_WEIGHTS['greeksSuitability'], delta_score,
    absolute_delta ? "abs delta #{absolute_delta.round(3)}#{theta_ratio ? ", theta/premium #{(theta_ratio * 100).round(2)}%" : ''}" : 'Groww delta unavailable',
    greek_available || !theta_rank.nil?, (absolute_delta ? 6.0 : 0) + (theta_rank ? 4.0 : 0)
  )

  add_component.call(
    'riskReward', STRIKE_SCORE_WEIGHTS['riskReward'], 0,
    'Option premium ATR, verified lot size, and transaction-cost-aware stop/target unavailable',
    false
  )

  candidate['score'] = score.round(1)
  candidate['scoreOutOf'] = 100
  candidate['availableWeight'] = available_weight
  candidate['scoreComponents'] = components
  candidate['trendChecks'] = trend_tests.map do |label, value|
    { 'check' => label, 'passed' => value }
  end
  candidate['directionalTrendConfirmed'] = !known_tests.empty? && known_tests.length == trend_tests.length &&
    known_tests.all? { |_label, value| value }
  candidate['deltaValid'] = delta_valid == true
  candidate
end

def rank_trade_candidates(current, previous, side_name, spot_price, market_context)
  side_key = side_name == 'call' ? 'CE' : 'PE'
  expiry_key = Date.strptime(current.fetch('expiry'), '%d %b %Y').iso8601
  maximum_distance = STRIKE_PRICE_RANGES.fetch(current.fetch('symbol'))
  contracts = current.fetch('contracts').each_with_object([]) do |(key, contract), result|
    expiry, strike_text, contract_side = key.split('|')
    next unless contract_side == side_key && expiry == expiry_key && contract.is_a?(Hash)

    strike = number(strike_text)
    next unless strike
    distance = (strike - spot_price).abs / spot_price
    next if (strike - spot_price).abs > maximum_distance

    moneyness = if distance <= 0.001
                  'ATM'
                elsif (side_name == 'call' && strike < spot_price) ||
                      (side_name == 'put' && strike > spot_price)
                  'ITM'
                else
                  'OTM'
                end
    ltp = number(contract['ltp'])
    oi = number(contract['oi'])
    volume = number(contract['volume'])
    bid = number(contract['bidPrice'])
    ask = number(contract['askPrice'])
    mid = bid && ask ? (bid + ask) / 2.0 : nil
    record = contract.merge(
      'key' => key,
      'strike' => strike,
      'ltp' => ltp,
      'oi' => oi,
      'volume' => volume&.to_i,
      'distance' => distance,
      'moneyness' => moneyness,
      'bidAskSpreadPercent' => bid&.positive? && ask && ask >= bid && mid&.positive? ?
        ((ask - bid) / mid) * 100 : nil
    )
    prior = previous && previous.fetch('contracts', {})[key]
    if prior.is_a?(Hash)
      old_oi = number(prior['oi'])
      old_ltp = number(prior['ltp'])
      old_iv = number(prior['iv'])
      record['oiChange'] = old_oi ? record['oi'] - old_oi : nil
      record['oiChangePercent'] = old_oi&.positive? ? (record['oiChange'].to_f / old_oi) * 100 : nil
      record['premiumChangePercent'] = old_ltp&.positive? && ltp&.positive? ?
        ((record['ltp'] - old_ltp) / old_ltp) * 100 : nil
      record['ivChange'] = old_iv && record['iv'] ? record['iv'] - old_iv : nil
    end
    record['oiHypothesis'] = if record['oiChange'].nil?
                               'No comparable 15-minute OI snapshot; neutral'
                             elsif record['oiChange'].positive? && record['premiumChangePercent']&.positive? &&
                                   directional_match(market_context['spotChange'], side_name)
                               'OI, premium and index aligned; participation hypothesis only'
                             elsif record['oiChange'].negative? && record['premiumChangePercent']&.positive? &&
                                   directional_match(market_context['spotChange'], side_name)
                               'Premium/index aligned with falling OI; covering hypothesis only'
                             else
                               'Mixed OI/price evidence; neutral, not directional alone'
                             end
    record['premiumOiPattern'] = if record['premiumChangePercent'].nil? || record['oiChange'].nil?
                                   'Collecting comparable premium/OI data'
                                 elsif record['premiumChangePercent'].positive? && record['oiChange'].positive?
                                   'Premium ↑ · OI ↑'
                                 elsif record['premiumChangePercent'].negative? && record['oiChange'].positive?
                                   'Premium ↓ · OI ↑'
                                 elsif record['premiumChangePercent'].positive? && record['oiChange'].negative?
                                   'Premium ↑ · OI ↓'
                                 elsif record['premiumChangePercent'].negative? && record['oiChange'].negative?
                                   'Premium ↓ · OI ↓'
                                 else
                                   'Premium/OI mixed'
                                 end
    result << record
  end
  candidates = contracts
  return {
    'status' => 'WAIT / NO TRADE',
    'reason' => "No #{side_key} strikes found within ±#{maximum_distance.to_i} points of spot.",
    'rankings' => [],
    'candidateCountWithinRange' => 0,
    'strikeRangePoints' => maximum_distance
  } if candidates.empty?

  candidates.each { |candidate| score_trade_candidate(candidate, candidates, side_name, market_context) }
  ranked = candidates.sort_by { |candidate| [-candidate['score'], candidate['distance']] }
  ranked.each_with_index { |candidate, index| candidate['rank'] = index + 1 }

  required_missing = lambda do |candidate|
    gates = []
    gates << 'Market/candles are stale or market is closed' unless market_context['live']
    gates << 'Contract symbol is unavailable' if candidate['tradingSymbol'].to_s.empty?
    gates << 'Candidate has no current premium, OI, or traded volume' unless
      candidate['ltp']&.positive? && candidate['oi'] && candidate['volume']&.positive?
    gates << "Absolute delta is unavailable or outside #{MIN_ABSOLUTE_DELTA}-#{MAX_ABSOLUTE_DELTA}" unless candidate['deltaValid']
    spread = candidate['bidAskSpreadPercent']
    gates << 'Bid/ask quote is unavailable' unless spread
    gates << "Bid/ask spread exceeds #{MAX_BID_ASK_SPREAD_PERCENT}% limit" if spread && spread > MAX_BID_ASK_SPREAD_PERCENT
    gates << 'Required directional trend checks are not all confirmed' unless candidate['directionalTrendConfirmed']
    gates << '15-minute option premium confirmation is unavailable or not positive' unless
      candidate['premiumChangePercent']&.positive?
    gates << 'Verified contract lot size is unavailable' unless candidate['lotSize']&.positive?
    gates << 'Premium-candle stop, cost-adjusted target, and risk/reward are unavailable'
    gates
  end
  ranked.each do |candidate|
    candidate['rejections'] = required_missing.call(candidate)
    score_status = candidate['score'] >= STRONG_CANDIDATE_SCORE ? 'STRONG CANDIDATE' :
      (candidate['score'] >= MIN_CANDIDATE_SCORE ? 'WATCH CANDIDATE' : 'WAIT / NO TRADE')
    candidate['status'] = candidate['rejections'].empty? ? score_status : 'WAIT / NO TRADE'
    candidate['status'] = 'WAIT / NO TRADE' if candidate['score'] < MIN_CANDIDATE_SCORE
    candidate['reason'] = candidate['rejections'].empty? ?
      'Research score only; thresholds are not calibrated for profitability.' :
      candidate['rejections'].join('. ') + '.'
    candidate.delete('key')
  end
  top = ranked.first
  top.merge(
    'status' => top['status'],
    'candidateCountWithinRange' => candidates.length,
    'strikeRangePoints' => maximum_distance,
    'rankings' => ranked.first(3).map do |candidate|
      candidate.reject { |key, _value| %w[scoreComponents trendChecks].include?(key) }
    end
  )
end

def build_trade_analysis(current, previous, now: Time.now)
  candles = current.fetch('candles')
  latest = candles.last
  supertrend = groww_supertrend(candles)
  candle_age = latest ? now.getlocal('+05:30') - latest['time'] : Float::INFINITY
  now_ist = now.getlocal('+05:30')
  market_open = nse_trading_session?(now_ist) &&
    now_ist.hour * 3600 + now_ist.min * 60 >= 9 * 3600 + 15 * 60 &&
    now_ist.hour * 3600 + now_ist.min * 60 <= 15 * 3600 + 30 * 60
  live = market_open && candle_age >= 0 && candle_age <= 10 * 60
  baseline_candle = if latest
                      candles.select { |candle| candle['time'] <= latest['time'] - OI_HISTORY_WINDOW_SECONDS }
                        .min_by { |candle| (candle['time'] - (latest['time'] - OI_HISTORY_WINDOW_SECONDS)).abs }
                    end
  baseline_candle = nil if baseline_candle &&
    (latest['time'] - baseline_candle['time'] - OI_HISTORY_WINDOW_SECONDS).abs > OI_HISTORY_TOLERANCE_SECONDS
  spot_change = latest && baseline_candle ? latest['close'] - baseline_candle['close'] : nil
  recent_candles = latest ? candles.select { |candle| candle['time'] >= latest['time'] - OI_HISTORY_WINDOW_SECONDS } : []
  spot_price = number(current['spotPrice'])
  raise FeedError, "Groww returned no underlying price for #{current.fetch('symbol')}." unless spot_price&.positive?
  indicators = market_indicators(candles, now: now)

  pcr_change = if previous && current['pcr'] && previous['pcr']
                 current['pcr'] - previous['pcr']
               end
  context = {
    'live' => live,
    'spotChange' => spot_change,
    'supertrend' => supertrend,
    'pcrChange' => pcr_change,
    'indicators' => indicators
  }
  {
    'supertrend' => supertrend,
    'spotChange' => spot_change,
    'pcr' => current['pcr'],
    'pcrChange' => pcr_change,
    'regime' => classify_market_regime(indicators),
    'indicators' => indicators,
    'support' => recent_candles.map { |candle| candle['low'] }.min,
    'resistance' => recent_candles.map { |candle| candle['high'] }.max,
    'call' => rank_trade_candidates(current, previous, 'call', spot_price, context),
    'put' => rank_trade_candidates(current, previous, 'put', spot_price, context)
  }
end

def option_change_summary(current, previous)
  current_contracts = current.fetch('contracts')
  previous_contracts = previous.fetch('contracts')
  comparable_keys = current_contracts.keys & previous_contracts.keys
  side_summaries = {}

  { 'CE' => 'call', 'PE' => 'put' }.each do |side_key, side_name|
    keys = comparable_keys.select { |key| key.end_with?("|#{side_key}") }
    current_total = keys.sum { |key| current_contracts.fetch(key).fetch('oi') }
    previous_total = keys.sum { |key| previous_contracts.fetch(key).fetch('oi') }
    increases = keys.each_with_object([]) do |key, result|
      change = current_contracts.fetch(key).fetch('oi') - previous_contracts.fetch(key).fetch('oi')
      next unless change.positive?

      strike = key.split('|')[1].to_f
      result << { 'strike' => strike, 'change' => change, 'oi' => current_contracts.fetch(key).fetch('oi') }
    end
    largest_increase = increases.max_by { |item| item['change'] }
    side_summaries[side_name] = {
      'change' => current_total - previous_total,
      'largestIncrease' => largest_increase
    }
  end

  {
    'symbol' => current.fetch('symbol'),
    'expiry' => current.fetch('expiry'),
    'call' => side_summaries.fetch('call'),
    'put' => side_summaries.fetch('put')
  }
end

def update_oi_history(current_by_symbol, now: Time.now)
  current_time = now.utc
  today_ist = now.getlocal('+05:30').to_date.iso8601
  current_sample = {
    'timestamp' => current_time.iso8601,
    'tradingDate' => today_ist,
    'symbols' => current_by_symbol.transform_values do |item|
      item.reject { |key, _value| key == 'candles' }
    end
  }

  @oi_history_lock.synchronize do
    history = @oi_history
    latest = history.last
    if latest && (current_time - Time.iso8601(latest.fetch('timestamp'))) < 60
      current_sample['timestamp'] = latest.fetch('timestamp')
      current_time = Time.iso8601(current_sample['timestamp'])
      history[-1] = current_sample
    else
      history << current_sample
    end
    history.reject! do |item|
      Time.iso8601(item.fetch('timestamp')) < current_time - OI_HISTORY_RETENTION_SECONDS
    end
    today_samples = history.select { |item| item['tradingDate'] == today_ist }

    baseline = today_samples.select do |item|
      Time.iso8601(item.fetch('timestamp')) < current_time
    end.min_by do |item|
      (Time.iso8601(item.fetch('timestamp')) - (current_time - OI_HISTORY_WINDOW_SECONDS)).abs
    end
    baseline_offset = if baseline
                        ((current_time - Time.iso8601(baseline.fetch('timestamp'))) -
                          OI_HISTORY_WINDOW_SECONDS).abs
                      end
    baseline = nil if baseline_offset && baseline_offset > OI_HISTORY_TOLERANCE_SECONDS

    symbol_changes = SYMBOLS.map do |symbol|
      current = current_by_symbol.fetch(symbol)
      previous = baseline && baseline.dig('symbols', symbol)
      if previous && previous['expiry'] == current['expiry']
        option_change_summary(current, previous).merge(
          'tradeAnalysis' => build_trade_analysis(current, previous)
        )
      else
        {
          'symbol' => symbol,
          'expiry' => current['expiry'],
          'call' => nil,
          'put' => nil,
          'tradeAnalysis' => build_trade_analysis(current, nil)
        }
      end
    end
    {
      'windowMinutes' => OI_HISTORY_WINDOW_SECONDS / 60,
      'referenceTime' => baseline && baseline.fetch('timestamp'),
      'availableAt' => today_samples.empty? ? nil :
        (Time.iso8601(today_samples.first.fetch('timestamp')) + OI_HISTORY_WINDOW_SECONDS).iso8601,
      'symbols' => symbol_changes
    }
  end
end

def fetch_groww_option_data(requested_expiries = {})
  token = groww_access_token
  today = Time.now.getlocal('+05:30').to_date
  SYMBOLS.map do |symbol|
    exchange = SYMBOL_EXCHANGES.fetch(symbol)
    index = fetch_groww_index_data(token, symbol, exchange, today, requested_expiries)
    index['candles'] = fetch_groww_index_candles(token, symbol, exchange, today)
    [symbol, index]
  end.to_h
end

def request_json(url, token: nil)
  uri = URI.parse(url)
  request = Net::HTTP::Get.new(uri)
  request['Accept'] = 'application/json'
  request['User-Agent'] = 'Index-OI-Dashboard/1.0'
  request['Authorization'] = "Bearer #{token}" unless token.to_s.empty?

  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https',
                             open_timeout: 10, read_timeout: 30) do |http|
    http.request(request)
  end
  unless response.is_a?(Net::HTTPSuccess)
    raise FeedError, "The data source returned an unsuccessful response (HTTP #{response.code})."
  end

  JSON.parse(response.body)
rescue JSON::ParserError
  raise FeedError, 'The data source returned invalid JSON.'
rescue IOError, SystemCallError, SocketError, Timeout::Error, URI::InvalidURIError
  raise FeedError, 'Could not connect to the data source.'
end

def instrument_master
  @instrument_lock.synchronize do
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    if @instrument_cache && @instrument_cache_at && now - @instrument_cache_at < INSTRUMENT_CACHE_TTL
      return @instrument_cache
    end

    master = request_json(INSTRUMENT_MASTER_URL)
    raise FeedError, 'Angel One instrument master response was not an array.' unless master.is_a?(Array)

    @instrument_cache = master
    @instrument_cache_at = now
    @instrument_cache
  end
end

def expiry_date(value)
  Date.strptime(value.to_s.upcase, '%d%b%Y')
rescue Date::Error
  nil
end

def select_option_contracts(master, symbol, now_ist: Time.now.getlocal('+05:30'))
  configuration = SMARTAPI_SYMBOLS.fetch(symbol)
  contracts = master.select do |item|
    item.is_a?(Hash) &&
      item['name'].to_s.upcase == symbol &&
      item['instrumenttype'] == 'OPTIDX' &&
      item['exch_seg'] == configuration['exchange']
  end
  today = now_ist.to_date
  latest_expiry_time = Time.new(today.year, today.month, today.day, 15, 30, 0, '+05:30')
  eligible = contracts.map do |item|
    date = expiry_date(item['expiry'])
    [date, item] if date && (date > today || (date == today && now_ist <= latest_expiry_time))
  end.compact
  nearest_expiry = eligible.map(&:first).min
  raise FeedError, "Angel One has no upcoming #{symbol} option expiry in its instrument master." unless nearest_expiry

  selected = eligible.select { |date, _item| date == nearest_expiry }.map(&:last)
  option_contracts = selected.map do |item|
    strike = number(item['strike'])
    next unless strike && strike.positive?

    option_symbol = item['symbol'].to_s
    side = option_symbol.end_with?('CE') ? 'call' : (option_symbol.end_with?('PE') ? 'put' : nil)
    next unless side

    {
      'token' => item['token'].to_s,
      'tradingSymbol' => option_symbol,
      'strike' => strike / 100,
      'side' => side
    }
  end.compact

  {
    'expiry' => nearest_expiry.strftime('%d %b %Y'),
    'contracts' => option_contracts
  }
end

def smartapi_quote_batch(exchange, contracts)
  smartapi_login
  response = smartapi_request(
    SMARTAPI_MARKET_QUOTE_PATH,
    { 'mode' => 'FULL', 'exchangeTokens' => { exchange => contracts.map { |item| item['token'] } } }
  )
  fetched = response.dig('data', 'fetched')
  unless fetched.is_a?(Array)
    raise FeedError, 'SmartAPI market quote response is missing its fetched contracts.'
  end

  fetched
end

def fetch_smartapi_option_data
  master = instrument_master
  selected = SYMBOLS.map do |symbol|
    [symbol, select_option_contracts(master, symbol)]
  end.to_h
  grouped = selected.flat_map do |symbol, details|
    details['contracts'].map do |contract|
      contract.merge('index' => symbol, 'exchange' => SMARTAPI_SYMBOLS.fetch(symbol)['exchange'])
    end
  end.group_by { |item| item['exchange'] }
  quotes_by_token = {}

  grouped.each do |exchange, contracts|
    contracts.each_slice(50) do |batch|
      smartapi_quote_batch(exchange, batch).each do |quote|
        quotes_by_token[quote['symbolToken'].to_s] = quote if quote.is_a?(Hash)
      end
    end
  end

  selected.map do |symbol, details|
    call = nil
    put = nil
    details['contracts'].each do |contract|
      quote = quotes_by_token[contract['token']]
      unless quote
        raise FeedError, "SmartAPI did not return a quote for #{contract['tradingSymbol']}."
      end

      oi = number(quote['opnInterest'] || quote['oi'])
      next unless oi

      candidate = { 'strike' => contract['strike'], 'oi' => oi.to_i }
      if contract['side'] == 'call'
        call = candidate if call.nil? || candidate['oi'] > call['oi']
      else
        put = candidate if put.nil? || candidate['oi'] > put['oi']
      end
    end

    unless call && put
      raise FeedError, "SmartAPI returned no call or put OI for #{symbol} at expiry #{details['expiry']}."
    end

    [symbol, { 'expiry' => details['expiry'], 'call' => call, 'put' => put }]
  end.to_h
end

def fetch_yahoo_spot(symbol, yahoo_symbol)
  encoded_symbol = URI.encode_www_form_component(yahoo_symbol)
  payload = request_json(
    "https://query1.finance.yahoo.com/v8/finance/chart/#{encoded_symbol}?range=1d&interval=1m"
  )
  chart = payload.dig('chart', 'result', 0)
  unless chart.is_a?(Hash)
    detail = payload.dig('chart', 'error', 'description')
    raise FeedError, detail || "Yahoo Finance returned no quote for #{symbol}."
  end

  meta = chart['meta'] || {}
  price = number(meta['regularMarketPrice'])
  raise FeedError, "Yahoo Finance returned no spot price for #{symbol}." unless price && price.positive?

  {
    'symbol' => symbol,
    'spotPrice' => price,
    'expiry' => nil,
    'call' => nil,
    'put' => nil,
    'quoteTime' => meta['regularMarketTime'] ? Time.at(meta['regularMarketTime']).utc.iso8601 : nil
  }
rescue NoMethodError
  raise FeedError, "Yahoo Finance returned an unexpected quote response for #{symbol}."
end

def fetch_external_provider
  items = if PROVIDER_URL.include?('{symbol}')
            SYMBOLS.map do |symbol|
              url = PROVIDER_URL.gsub('{symbol}', URI.encode_www_form_component(symbol))
              normalize_symbol(request_json(url, token: PROVIDER_TOKEN), symbol)
            end
          else
            payload = request_json(PROVIDER_URL, token: PROVIDER_TOKEN)
            unless payload.is_a?(Hash) && payload['symbols'].is_a?(Array)
              raise FeedError,
                    'A single OI_PROVIDER_URL must return all three indices in a "symbols" array. Use {symbol} in the URL to fetch each index separately.'
            end
            SYMBOLS.map { |symbol| normalize_symbol(payload, symbol) }
          end

  { 'lastUpdated' => Time.now.utc.iso8601, 'symbols' => items, 'source' => 'provider' }
end

def fetch_feed(requested_expiries = {})
  fetch_nse_holiday_data
  missing_groww = groww_credentials_missing
  unless missing_groww.empty?
    raise FeedError, "Groww is the only dashboard data source. Add these values to .env: #{missing_groww.join(', ')}."
  end
  if !GROWW_API_SECRET.empty? && !GROWW_TOTP_SECRET.empty?
    raise FeedError, 'Set only one of GROWW_API_SECRET or GROWW_TOTP_SECRET in .env.'
  end

  oi_by_symbol = fetch_groww_option_data(requested_expiries)
  oi_change = update_oi_history(oi_by_symbol)
  items = SYMBOLS.map do |symbol|
    oi_by_symbol.fetch(symbol).reject { |key, _value| key == 'contracts' }
  end
  {
    'lastUpdated' => Time.now.utc.iso8601,
    'symbols' => items,
    'oiChange' => oi_change,
    'selectedExpiries' => oi_by_symbol.transform_values { |item| item['expiryDate'] },
    'source' => 'groww'
  }
end

def synthetic_preview_candidate(strike:, rank:, score:, side:, premium:, oi_change:, volume:)
  {
    'strike' => strike,
    'moneyness' => 'PREVIEW',
    'ltp' => premium,
    'volume' => volume,
    'oi' => 12_345 + volume,
    'oiChange' => oi_change,
    'oiChangePercent' => 2.4,
    'premiumChangePercent' => 1.8,
    'premiumOiPattern' => 'SYNTHETIC UI PREVIEW ONLY',
    'delta' => side == 'call' ? 0.56 : -0.54,
    'iv' => 18.2,
    'bidAskSpreadPercent' => 0.7,
    'score' => score,
    'scoreOutOf' => 100,
    'availableWeight' => 95,
    'rank' => rank,
    'status' => 'PREVIEW ONLY',
    'reason' => 'Synthetic UI fixture. This is not a market signal or trade recommendation.',
    'rejections' => ['Preview-only fixture; no live market data or actual contract quote is used.'],
    'scoreComponents' => {
      'premiumMomentum' => {
        'score' => 14, 'weight' => 20, 'available' => true,
        'detail' => 'Illustrative display value only'
      },
      'underlyingTrend' => {
        'score' => 15, 'weight' => 20, 'available' => true,
        'detail' => 'Illustrative display value only'
      },
      'volumeLiquidity' => {
        'score' => 11, 'weight' => 15, 'available' => true,
        'detail' => 'Illustrative display value only'
      },
      'oiPositioning' => {
        'score' => 9, 'weight' => 15, 'available' => true,
        'detail' => 'Illustrative display value only'
      },
      'volatility' => {
        'score' => 9, 'weight' => 15, 'available' => true,
        'detail' => 'Illustrative display value only'
      },
      'greeksSuitability' => {
        'score' => 6, 'weight' => 10, 'available' => true,
        'detail' => 'Illustrative display value only'
      },
      'riskReward' => {
        'score' => 0, 'weight' => 5, 'available' => false,
        'detail' => 'No real stop, target, costs, or risk sizing in this fixture'
      }
    }
  }
end

def synthetic_preview_expiry(symbol, requested_expiries)
  available = %w[PREVIEW-A PREVIEW-B PREVIEW-C]
  requested = requested_expiries[symbol]
  return available.first if requested.nil? || requested.empty?
  return requested if available.include?(requested)

  raise FeedError, "Selected preview expiry #{requested} is not available for #{symbol}."
end

def synthetic_preview_feed(requested_expiries = {})
  preview_expiries = ['PREVIEW-A', 'PREVIEW-B', 'PREVIEW-C']
  nifty_expiry = synthetic_preview_expiry('NIFTY', requested_expiries)
  sensex_expiry = synthetic_preview_expiry('SENSEX', requested_expiries)
  symbols = [
    {
      'symbol' => 'NIFTY',
      'spotPrice' => 25_100.0,
      'expiry' => nifty_expiry,
      'expiryDate' => nifty_expiry,
      'availableExpiries' => preview_expiries,
      'strikeRangePoints' => STRIKE_PRICE_RANGES.fetch('NIFTY'),
      'candidateCountWithinRange' => 3,
      'call' => { 'strike' => 25_200.0, 'oi' => 150_000 },
      'put' => { 'strike' => 25_000.0, 'oi' => 142_000 }
    },
    {
      'symbol' => 'SENSEX',
      'spotPrice' => 82_100.0,
      'expiry' => sensex_expiry,
      'expiryDate' => sensex_expiry,
      'availableExpiries' => preview_expiries,
      'strikeRangePoints' => STRIKE_PRICE_RANGES.fetch('SENSEX'),
      'candidateCountWithinRange' => 3,
      'call' => { 'strike' => 82_200.0, 'oi' => 89_000 },
      'put' => { 'strike' => 82_000.0, 'oi' => 84_000 }
    }
  ]
  comparison_symbols = symbols.map do |item|
    spot = item['spotPrice']
    call_candidates = [
      synthetic_preview_candidate(
        strike: spot + 100, rank: 1, score: 72.4, side: 'call',
        premium: 125.5, oi_change: 2_100, volume: 18_500
      ),
      synthetic_preview_candidate(
        strike: spot, rank: 2, score: 68.1, side: 'call',
        premium: 148.0, oi_change: 1_700, volume: 16_200
      ),
      synthetic_preview_candidate(
        strike: spot - 100, rank: 3, score: 61.6, side: 'call',
        premium: 182.5, oi_change: 800, volume: 12_300
      )
    ]
    put_candidates = [
      synthetic_preview_candidate(
        strike: spot - 100, rank: 1, score: 70.2, side: 'put',
        premium: 119.0, oi_change: 1_900, volume: 17_800
      ),
      synthetic_preview_candidate(
        strike: spot, rank: 2, score: 66.8, side: 'put',
        premium: 146.5, oi_change: 1_400, volume: 15_500
      ),
      synthetic_preview_candidate(
        strike: spot + 100, rank: 3, score: 60.9, side: 'put',
        premium: 179.0, oi_change: 700, volume: 11_900
      )
    ]
    sample_indicator = lambda do |close, vwap, ema20, ema50, rsi|
      {
        'close' => close, 'vwap' => vwap, 'ema20' => ema20, 'ema50' => ema50,
        'rsi14' => rsi, 'rsi14Previous' => rsi - 1
      }
    end
    {
      'symbol' => item['symbol'],
      'expiry' => item['expiry'],
      'strikeRangePoints' => item['strikeRangePoints'],
      'call' => { 'change' => 3_200, 'largestIncrease' => { 'strike' => spot + 100, 'change' => 2_100 } },
      'put' => { 'change' => 2_800, 'largestIncrease' => { 'strike' => spot - 100, 'change' => 1_900 } },
      'tradeAnalysis' => {
        'regime' => 'PREVIEW ONLY',
        'supertrend' => { 'direction' => 'PREVIEW ONLY', 'level' => spot },
        'spotChange' => 24.5,
        'pcr' => 0.94,
        'pcrChange' => 0.03,
        'support' => spot - 150,
        'resistance' => spot + 150,
        'indicators' => {
          'fiveMinute' => sample_indicator.call(spot + 25, spot, spot + 10, spot - 5, 58),
          'fifteenMinute' => sample_indicator.call(spot + 15, spot - 3, spot + 7, spot - 8, 56)
        },
        'call' => call_candidates.first.merge('rankings' => call_candidates),
        'put' => put_candidates.first.merge('rankings' => put_candidates)
      }
    }
  end

  {
    'source' => 'test-preview',
    'testPreview' => true,
    'lastUpdated' => nil,
    'symbols' => symbols,
    'selectedExpiries' => symbols.each_with_object({}) do |item, result|
      result[item['symbol']] = item['expiryDate']
    end,
    'oiChange' => {
      'windowMinutes' => OI_HISTORY_WINDOW_SECONDS / 60,
      'referenceTime' => nil,
      'availableAt' => nil,
      'symbols' => comparison_symbols
    }
  }
end

def json_response(response, status, payload)
  body = JSON.generate(payload)
  response.status = status
  response['Content-Type'] = 'application/json; charset=utf-8'
  response['Cache-Control'] = 'no-store'
  response.body = body
end

def dashboard_operating_window?(time)
  india_time = time.getlocal('+05:30')
  india_time.wday.between?(1, 5) &&
    india_time.hour >= 9 && india_time.hour < 16
end

def seconds_until_dashboard_close(time)
  india_time = time.getlocal('+05:30')
  closing_time = Time.new(
    india_time.year, india_time.month, india_time.day, 16, 0, 0, '+05:30'
  )
  [closing_time - india_time, 0].max
end

if $PROGRAM_NAME == __FILE__
  allow_outside_hours = ENV['DASHBOARD_ALLOW_OUTSIDE_HOURS'] == '1'
  unless allow_outside_hours || dashboard_operating_window?(Time.now)
    warn 'Dashboard starts only on weekdays from 09:00 to 16:00 IST.'
    exit 0
  end

  server = WEBrick::HTTPServer.new(
    Port: PORT,
    BindAddress: '127.0.0.1',
    AccessLog: [],
    Logger: WEBrick::Log.new(File::NULL, WEBrick::Log::FATAL)
  )

  server.mount_proc('/') do |request, response|
    unless request.request_method == 'GET'
      response['Allow'] = 'GET'
      response.status = 405
      next
    end

    if request.path == '/api/oi'
      begin
        requested_expiries = SYMBOLS.each_with_object({}) do |symbol, result|
          value = request.query["expiry_#{symbol}"]
          result[symbol] = value unless value.to_s.empty?
        end
        payload = TEST_PREVIEW_ENABLED ? synthetic_preview_feed(requested_expiries) : fetch_feed(requested_expiries)
        json_response(response, 200, payload)
      rescue FeedError => error
        json_response(response, 503, { 'error' => error.message })
      end
      next
    end
    if request.path == '/api/trading'
      begin
        json_response(response, 200, fetch_groww_trading_summary)
      rescue FeedError => error
        json_response(response, 503, { 'error' => error.message })
      end
      next
    end
    if request.path == '/api/holidays'
      json_response(response, 200, fetch_nse_holiday_data)
      next
    end

    relative_path = {
      '/' => 'index.html',
      '/index.html' => 'index.html',
      '/style.css' => 'style.css',
      '/app.js' => 'app.js'
    }[request.path]
    unless relative_path
      response.status = 404
      next
    end

    target = ROOT + relative_path
    response['Content-Type'] = WEBrick::HTTPUtils.mime_type(target.extname, WEBrick::HTTPUtils::DefaultMimeTypes)
    response['X-Content-Type-Options'] = 'nosniff'
    response.body = target.binread
  end

  trap('INT') { server.shutdown }
  trap('TERM') { server.shutdown }
  puts "Open-interest dashboard running at http://127.0.0.1:#{PORT}"
  unless allow_outside_hours
    Thread.new do
      sleep seconds_until_dashboard_close(Time.now)
      server.shutdown
    end
  end
  server.start
end
