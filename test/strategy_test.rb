require 'minitest/autorun'
require_relative '../server'

class StrategyTest < Minitest::Test
  def test_ema_uses_seed_average_then_smoothing
    assert_equal [nil, nil, 2.0, 3.0, 4.0], exponential_moving_average([1, 2, 3, 4, 5], 3)
  end

  def test_rsi_marks_a_continuous_rise_as_overbought
    assert_equal 100.0, relative_strength_index((1..20).map(&:to_f))
  end

  def test_aggregate_candles_keeps_only_complete_intervals
    start = Time.new(2025, 1, 2, 9, 15, 0, '+05:30')
    candles = 5.times.map do |index|
      price = 100.0 + index
      {
        'time' => start + index * 5 * 60,
        'open' => price,
        'high' => price + 1,
        'low' => price - 1,
        'close' => price + 0.5,
        'volume' => 10
      }
    end

    aggregated = aggregate_candles(candles, 15 * 60)
    assert_equal 1, aggregated.length
    assert_equal 102.5, aggregated.first['close']
    assert_equal 30, aggregated.first['volume']
  end

  def test_rankings_return_near_atm_candidates_and_fail_closed_without_risk_inputs
    date = Date.today
    expiry = date.iso8601
    current_contracts = {}
    previous_contracts = {}
    [99.0, 100.0, 101.0].each_with_index do |strike, index|
      key = "#{expiry}|#{strike}|CE"
      current_contracts[key] = {
        'ltp' => 12.0 + index,
        'oi' => 1_100 + index * 100,
        'volume' => 200 + index * 10,
        'tradingSymbol' => "TEST#{index}",
        'delta' => 0.55,
        'theta' => -0.1,
        'iv' => 15.0
      }
      previous_contracts[key] = { 'ltp' => 10.0, 'oi' => 1_000, 'iv' => 14.5 }
    end
    current = {
      'symbol' => 'NIFTY',
      'expiry' => date.strftime('%d %b %Y'),
      'contracts' => current_contracts
    }
    previous = { 'contracts' => previous_contracts }
    indicators = {
      'fiveMinute' => {
        'close' => 101.0, 'vwap' => 100.0, 'ema20' => 101.0, 'ema50' => 100.0,
        'rsi14' => 60.0, 'rsi14Previous' => 58.0
      },
      'fifteenMinute' => {
        'close' => 101.0, 'vwap' => 100.0, 'ema20' => 101.0, 'ema50' => 100.0,
        'rsi14' => 60.0, 'rsi14Previous' => 58.0
      },
      'openingRange' => { 'high' => 100.5 }
    }
    context = {
      'live' => true,
      'spotChange' => 1.0,
      'supertrend' => { 'direction' => 'bullish' },
      'indicators' => indicators
    }

    result = rank_trade_candidates(current, previous, 'call', 100.0, context)

    assert_equal 3, result.fetch('rankings').length
    assert_equal 3, result.fetch('candidateCountWithinRange')
    assert_equal 500.0, result.fetch('strikeRangePoints')
    assert_equal 'WAIT / NO TRADE', result.fetch('status')
    assert_equal 1, result.fetch('rank')
    assert_operator result.fetch('score'), :>, 0
    assert result.fetch('rejections').any? { |reason| reason.include?('Bid/ask') }
    assert result.fetch('rejections').any? { |reason| reason.include?('risk/reward') }
    assert_equal 100.0, STRIKE_SCORE_WEIGHTS.values.sum
  end

  def test_ui_preview_is_explicit_and_never_claims_market_data
    preview = synthetic_preview_feed

    assert_equal 'test-preview', preview.fetch('source')
    assert_equal true, preview.fetch('testPreview')
    assert_nil preview.fetch('lastUpdated')
    assert_equal %w[NIFTY SENSEX], preview.fetch('symbols').map { |item| item.fetch('symbol') }
    preview.fetch('oiChange').fetch('symbols').each do |item|
      %w[call put].each do |side|
        candidate = item.fetch('tradeAnalysis').fetch(side)
        assert_equal 'PREVIEW ONLY', candidate.fetch('status')
        assert_match(/Synthetic UI fixture/, candidate.fetch('reason'))
        assert_equal 3, candidate.fetch('rankings').length
      end

      def test_strike_selection_uses_inclusive_symbol_specific_spot_windows
        { 'NIFTY' => [25_100.0, 500.0], 'SENSEX' => [82_100.0, 1_000.0] }.each do |symbol, (spot, range)|
          date = Date.today
          expiry = date.iso8601
          strikes = [spot - range - 1, spot - range, spot, spot + range, spot + range + 1]
          contracts = strikes.each_with_object({}) do |strike, result|
            result["#{expiry}|#{strike}|CE"] = {
              'ltp' => 100.0, 'oi' => 1_000, 'volume' => 500,
              'tradingSymbol' => "#{symbol}#{strike}", 'delta' => 0.55
            }
          end
          current = {
            'symbol' => symbol,
            'expiry' => date.strftime('%d %b %Y'),
            'contracts' => contracts
          }
          result = rank_trade_candidates(current, nil, 'call', spot, {
            'live' => true,
            'spotChange' => 1.0,
            'supertrend' => { 'direction' => 'bullish' },
            'indicators' => {}
          })

          assert_equal 3, result.fetch('candidateCountWithinRange')
          assert result.fetch('rankings').all? { |item| (item.fetch('strike') - spot).abs <= range }
          assert_equal range, result.fetch('strikeRangePoints')
        end
      end

      def test_expiry_selection_uses_nearest_by_default_and_rejects_unavailable_date
        available = [Date.new(2026, 10, 22), Date.new(2026, 10, 29)]

        assert_equal available.first, selected_expiry_for('NIFTY', {}, available)
        assert_equal available.last, selected_expiry_for('NIFTY', { 'NIFTY' => '2026-10-29' }, available)
        error = assert_raises(FeedError) do
          selected_expiry_for('NIFTY', { 'NIFTY' => '2026-11-05' }, available)
        end
        assert_match(/not available/, error.message)
      end

      def test_preview_expiry_selection_is_labeled_and_validated
        assert_equal 'PREVIEW-A', synthetic_preview_expiry('NIFTY', {})
        assert_equal 'PREVIEW-C', synthetic_preview_expiry('NIFTY', { 'NIFTY' => 'PREVIEW-C' })
        assert_raises(FeedError) do
          synthetic_preview_expiry('NIFTY', { 'NIFTY' => '2026-10-22' })
        end
      end
    end
  end
end
