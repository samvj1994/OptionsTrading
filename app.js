const updatedLabel = document.getElementById('last-updated');
const statusPill = document.getElementById('feed-status');
const notice = document.getElementById('feed-notice');
const refreshButton = document.getElementById('refresh-button');
const oiChangeCards = document.getElementById('oi-change-cards');
const oiChangeStatus = document.getElementById('oi-change-status');
const oiChangeTemplate = document.getElementById('oi-change-card-template');
const marketTab = document.getElementById('market-tab');
const tradingTab = document.getElementById('trading-tab');
const marketPanel = document.getElementById('market-panel');
const tradingPanel = document.getElementById('trading-panel');
const sessionDateSelect = document.getElementById('session-date');
const chargesInput = document.getElementById('charges-input');

const numberFormat = new Intl.NumberFormat('en-IN', { maximumFractionDigits: 2 });
const currencyFormat = new Intl.NumberFormat('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const marketOpenSeconds = 9 * 60 * 60 + 15 * 60;
const marketCloseSeconds = 15 * 60 * 60 + 30 * 60;
const refreshIntervalSeconds = 5 * 60;
const tradingRefreshIntervalSeconds = 5 * 60;
const indiaClock = new Intl.DateTimeFormat('en-GB', {
  timeZone: 'Asia/Kolkata',
  weekday: 'short',
  hour: '2-digit',
  minute: '2-digit',
  second: '2-digit',
  hourCycle: 'h23',
});
const tradingWeekdays = new Set(['Mon', 'Tue', 'Wed', 'Thu', 'Fri']);
const scoreFactorLabels = {
  premiumMomentum: 'Premium',
  underlyingTrend: 'Trend',
  volumeLiquidity: 'Liquidity',
  oiPositioning: 'OI',
  volatility: 'IV',
  greeksSuitability: 'Greeks',
  riskReward: 'Risk'
};
let requestInProgress = false;
let refreshTimer;
let holidays = new Set();
let holidayData = null;
let tradingSummary = null;
let tradingRequestInProgress = false;
let activeTab = 'market';
let calendarWarning = '';
let testPreviewMode = false;
let selectedExpiries = {};

const journalStorageKey = 'live-oi-strike-analyzer-trade-journal-v1';
const chargesStorageKey = 'live-oi-strike-analyzer-contract-note-charges-v1';
const journalInsightLabels = {
  'late-entry': 'Late entry / chased',
  'early-exit': 'Exited too early',
  oversized: 'Position too large',
  'moved-stop': 'Moved / skipped stop',
  'no-trigger': 'Entered without trigger',
  overtrade: 'Overtrading',
  revenge: 'Revenge trade',
  other: 'Other',
  calm: 'Calm / patient',
  confident: 'Confident',
  hesitant: 'Hesitant',
  fearful: 'Fearful',
  fomo: 'FOMO / chasing',
  frustrated: 'Frustrated'
};

function formatNumber(value) {
  if (value === null || value === undefined || value === '' || !Number.isFinite(Number(value))) {
    return '—';
  }
  return numberFormat.format(Number(value));
}

function formatSignedNumber(value) {
  if (value === null || value === undefined || !Number.isFinite(Number(value))) {
    return '—';
  }
  const amount = Number(value);
  return `${amount > 0 ? '+' : ''}${numberFormat.format(amount)}`;
}

function formatRupees(value, signed = false) {
  if (value === null || value === undefined || !Number.isFinite(Number(value))) return '—';
  const amount = Number(value);
  if (signed && amount < 0) return `-₹${currencyFormat.format(Math.abs(amount))}`;
  if (signed && amount > 0) return `+₹${currencyFormat.format(amount)}`;
  return `₹${currencyFormat.format(amount)}`;
}

function indiaDateString(date = new Date()) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat('en-CA', {
      timeZone: 'Asia/Kolkata',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
    }).formatToParts(date).map(({ type, value }) => [type, value]),
  );
  return `${parts.year}-${parts.month}-${parts.day}`;
}

function dateLabel(dateString, options = { weekday: 'short', day: '2-digit', month: 'short', year: 'numeric' }) {
  const date = new Date(`${dateString}T12:00:00Z`);
  return new Intl.DateTimeFormat('en-IN', { timeZone: 'UTC', ...options }).format(date);
}

function formatIndiaTime(value) {
  if (!value) return '—';
  return new Date(value).toLocaleTimeString('en-IN', {
    timeZone: 'Asia/Kolkata',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  });
}

function expiryOptionLabel(value, isPreview) {
  if (isPreview) return `${value.replace('PREVIEW-', 'Preview ')} · synthetic`;
  return dateLabel(value, { day: '2-digit', month: 'short', year: 'numeric' });
}

function safeLocalRead(key) {
  try {
    const value = localStorage.getItem(key);
    const parsed = value ? JSON.parse(value) : {};
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
  } catch (error) {
    console.warn(`Could not read local journal data (${key}).`, error);
    return {};
  }
}

function safeLocalWrite(key, value) {
  try {
    localStorage.setItem(key, JSON.stringify(value));
    return true;
  } catch (error) {
    console.error(`Could not save local journal data (${key}).`, error);
    return false;
  }
}

function nextCalendarSessions(count = 5) {
  const result = [];
  const today = indiaDateString();
  const [year, month, day] = today.split('-').map(Number);
  for (let offset = 1; offset <= 370 && result.length < count; offset += 1) {
    const date = new Date(Date.UTC(year, month - 1, day + offset)).toISOString().slice(0, 10);
    const weekday = new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', weekday: 'short' })
      .format(new Date(`${date}T12:00:00Z`));
    if (tradingWeekdays.has(weekday) && !holidays.has(date)) result.push(date);
  }
  return result;
}

function renderCalendar() {
  const status = document.getElementById('calendar-status');
  const sessionsList = document.getElementById('upcoming-sessions');
  const holidaysList = document.getElementById('upcoming-holidays');
  const sourceLink = document.getElementById('calendar-source');
  sessionsList.replaceChildren();
  holidaysList.replaceChildren();
  if (holidayData) {
    sourceLink.href = holidayData.source || 'https://www.nseindia.com/resources/exchange-communication-holidays';
    const updated = holidayData.updatedAt ? ` · Updated ${formatIndiaTime(holidayData.updatedAt)} IST` : '';
    const scope = holidayData.scope ? ` ${holidayData.scope}` : '';
    status.textContent = holidayData.status === 'live'
      ? `${holidayData.sourceName || 'Official exchange calendar'}${updated}.${scope}`
      : `${holidayData.warning || 'Official calendar unavailable.'} Weekday schedule will be used until it can refresh.${scope}`;
  } else {
    status.textContent = 'Fetching the official NSE holiday calendar…';
  }

  for (const date of nextCalendarSessions(5)) {
    const item = document.createElement('li');
    item.textContent = dateLabel(date);
    sessionsList.appendChild(item);
  }
  if (!sessionsList.childElementCount) {
    const item = document.createElement('li');
    item.className = 'calendar-empty';
    item.textContent = 'No upcoming sessions in the calendar range.';
    sessionsList.appendChild(item);
  }

  const today = indiaDateString();
  const upcomingHolidays = (holidayData?.entries || []).filter((item) => item.date >= today).slice(0, 6);
  for (const holiday of upcomingHolidays) {
    const item = document.createElement('li');
    item.textContent = `${dateLabel(holiday.date)} · ${holiday.description || 'Market holiday'}`;
    holidaysList.appendChild(item);
  }
  if (!upcomingHolidays.length) {
    const item = document.createElement('li');
    item.className = 'calendar-empty';
    item.textContent = holidayData?.status === 'unavailable'
      ? 'Holiday dates unavailable; check the official source.'
      : 'No further NSE holidays in the returned calendar.';
    holidaysList.appendChild(item);
  }

  const selected = sessionDateSelect.value;
  const options = [{ value: today, label: `Today · ${dateLabel(today)}` }]
    .concat(nextCalendarSessions(5).map((date, index) => ({
      value: date,
      label: `${index === 0 ? 'Next session' : `Session +${index + 1}`} · ${dateLabel(date)}`,
    })));
  sessionDateSelect.replaceChildren();
  for (const option of options) {
    const element = document.createElement('option');
    element.value = option.value;
    element.textContent = option.label;
    sessionDateSelect.appendChild(element);
  }
  sessionDateSelect.value = options.some((option) => option.value === selected) ? selected : today;
  refreshTradingForSelectedDate();
  scheduleNextRefresh();
}

async function refreshHolidays() {
  try {
    const response = await fetch(`/api/holidays?ts=${Date.now()}`, { cache: 'no-store' });
    const payload = await response.json();
    if (!response.ok) throw new Error(payload.error || `Holiday calendar request failed (${response.status}).`);
    holidayData = payload;
    holidays = new Set(Array.isArray(payload.dates) ? payload.dates : []);
    calendarWarning = payload.status === 'live' ? '' : (payload.warning || 'Official holiday calendar unavailable.');
    renderCalendar();
  } catch (error) {
    calendarWarning = error instanceof Error ? error.message : 'Official holiday calendar unavailable.';
    holidayData = {
      status: 'unavailable',
      dates: [],
      entries: [],
      source: 'https://www.nseindia.com/resources/exchange-communication-holidays',
      warning: calendarWarning,
    };
    holidays = new Set();
    renderCalendar();
    console.error('Exchange holiday refresh failed:', error);
  }
}

function formatTradeTime(value) {
  if (!value) return '—';
  return new Date(value).toLocaleTimeString('en-IN', {
    timeZone: 'Asia/Kolkata',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  });
}

function setMetricValue(id, value, pnl = false) {
  const element = document.getElementById(id);
  element.textContent = value;
  const amount = pnl === true ? Number(value) : Number(pnl);
  if (pnl !== false && Number.isFinite(amount)) {
    element.dataset.sign = amount > 0 ? 'positive' : (amount < 0 ? 'negative' : 'flat');
  } else {
    delete element.dataset.sign;
  }
}

function emotionNotes() {
  const value = safeLocalRead(journalStorageKey);
  return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
}

function saveEmotionNote(tradeId, field, value, cycle) {
  const journal = emotionNotes();
  journal[tradeId] = {
    ...(journal[tradeId] || {}),
    [field]: value,
    sessionDate: sessionDateSelect.value || '',
    realizedPnl: Number(cycle.realizedPnl),
    symbol: cycle.symbol || '—'
  };
  return safeLocalWrite(journalStorageKey, journal);
}

function journalSelect(cycle, note, field, label, options) {
  const labelElement = document.createElement('label');
  labelElement.className = 'journal-field';
  const caption = document.createElement('span');
  caption.textContent = label;
  const select = document.createElement('select');
  select.className = 'journal-control';
  select.setAttribute('aria-label', `${label} for ${cycle.symbol || 'trade'}`);
  const placeholder = document.createElement('option');
  placeholder.value = '';
  placeholder.textContent = 'Select…';
  select.appendChild(placeholder);
  for (const [value, text] of options) {
    const option = document.createElement('option');
    option.value = value;
    option.textContent = text;
    select.appendChild(option);
  }
  select.value = note[field] || '';
  select.addEventListener('change', () => {
    if (!saveEmotionNote(cycle.id, field, select.value, cycle)) return;
    note[field] = select.value;
    refreshTradeReview(note, labelElement);
  });
  labelElement.append(caption, select);
  return labelElement;
}

function journalNumber(cycle, note, field, label) {
  const labelElement = document.createElement('label');
  labelElement.className = 'journal-field';
  const caption = document.createElement('span');
  caption.textContent = label;
  const input = document.createElement('input');
  input.type = 'number';
  input.min = '0';
  input.step = '0.01';
  input.placeholder = '₹ value';
  input.className = 'journal-control';
  input.setAttribute('aria-label', `${label} for ${cycle.symbol || 'trade'}`);
  input.value = note[field] || '';
  input.addEventListener('change', () => {
    if (!saveEmotionNote(cycle.id, field, input.value, cycle)) return;
    note[field] = input.value;
    refreshTradeReview(note, labelElement);
  });
  labelElement.append(caption, input);
  return labelElement;
}

function journalText(cycle, note, field, label, placeholder, maxLength = 180) {
  const labelElement = document.createElement('label');
  labelElement.className = 'journal-field journal-field-wide';
  const caption = document.createElement('span');
  caption.textContent = label;
  const input = document.createElement('input');
  input.type = 'text';
  input.maxLength = maxLength;
  input.placeholder = placeholder;
  input.className = 'journal-control';
  input.setAttribute('aria-label', `${label} for ${cycle.symbol || 'trade'}`);
  input.value = note[field] || '';
  input.addEventListener('change', () => {
    if (!saveEmotionNote(cycle.id, field, input.value.trim(), cycle)) return;
    note[field] = input.value.trim();
    refreshTradeReview(note, labelElement);
  });
  labelElement.append(caption, input);
  return labelElement;
}

function refreshTradeReview(note, fieldElement) {
  const details = fieldElement.closest('details');
  const summary = details?.querySelector('summary');
  if (summary) {
    summary.textContent = reviewComplete(note) ? 'Reviewed' : 'Review trade';
    summary.classList.toggle('is-complete', reviewComplete(note));
  }
  renderJournalInsights();
}

function reviewComplete(note) {
  return ['setup', 'entryTrigger', 'entryEmotion', 'exitReason', 'mistake', 'plan']
    .every((field) => Boolean(note[field]));
}

function renderJournalInsights() {
  const journal = emotionNotes();
  const entries = Object.values(journal).filter((entry) => entry && typeof entry === 'object');
  const complete = entries.filter(reviewComplete);
  const adherenceEntries = entries.filter((entry) => entry.plan === 'yes' || entry.plan === 'no');
  const followed = adherenceEntries.filter((entry) => entry.plan === 'yes').length;
  document.getElementById('plan-adherence').textContent = adherenceEntries.length
    ? `${Math.round((followed / adherenceEntries.length) * 100)}%`
    : '—';
  document.getElementById('journal-review-count').textContent =
    `${complete.length} complete review${complete.length === 1 ? '' : 's'} · ${entries.length - complete.length} incomplete`;

  const mistakes = entries
    .filter((entry) => entry.mistake && entry.mistake !== 'none')
    .reduce((counts, entry) => {
      const current = counts[entry.mistake] || { count: 0, pnl: 0 };
      current.count += 1;
      current.pnl += Number.isFinite(Number(entry.realizedPnl)) ? Number(entry.realizedPnl) : 0;
      counts[entry.mistake] = current;
      return counts;
    }, {});
  const topMistake = Object.entries(mistakes).sort((a, b) => b[1].count - a[1].count)[0];
  const emotionCounts = entries
    .filter((entry) => entry.entryEmotion)
    .reduce((counts, entry) => {
      counts[entry.entryEmotion] = (counts[entry.entryEmotion] || 0) + 1;
      return counts;
    }, {});
  const commonEmotion = Object.entries(emotionCounts).sort((a, b) => b[1] - a[1])[0];
  const insights = [
    `${complete.length}/${entries.length} reviews complete`,
    topMistake
      ? `Most tagged: ${journalInsightLabels[topMistake[0]] || topMistake[0]} ×${topMistake[1].count} · cycle P&L ${formatRupees(topMistake[1].pnl, true)}`
      : 'No repeated mistake tagged yet',
    commonEmotion ? `Common entry state: ${journalInsightLabels[commonEmotion[0]] || commonEmotion[0]} (${commonEmotion[1]})` : 'Entry emotions not logged yet'
  ];
  document.getElementById('journal-emotion-summary').textContent = insights.join(' · ');
}

function renderTradeCycles(cycles) {
  const tbody = document.getElementById('trade-rows');
  tbody.replaceChildren();
  const journal = emotionNotes();
  for (const cycle of cycles) {
    const note = journal[cycle.id] || {};
    const row = document.createElement('tr');
    const values = [
      `${formatTradeTime(cycle.entryTime)} → ${formatTradeTime(cycle.exitTime)}`,
      `${cycle.symbol || '—'} · ${cycle.side || '—'}`,
      formatNumber(cycle.quantity),
      `${formatRupees(cycle.entryPrice)} → ${formatRupees(cycle.exitPrice)}`,
      formatRupees(cycle.realizedPnl, true),
    ];
    for (const [index, value] of values.entries()) {
      const cell = document.createElement('td');
      cell.textContent = value;
      if (index === 4) cell.className = Number(cycle.realizedPnl) >= 0 ? 'trade-pnl-positive' : 'trade-pnl-negative';
      row.appendChild(cell);
    }

    const reviewCell = document.createElement('td');
    reviewCell.className = 'journal-review-cell';
    const review = document.createElement('details');
    review.className = 'journal-review';
    const summary = document.createElement('summary');
    summary.textContent = reviewComplete(note) ? 'Reviewed' : 'Review trade';
    summary.classList.toggle('is-complete', reviewComplete(note));
    review.appendChild(summary);
    const fields = document.createElement('div');
    fields.className = 'journal-review-fields';
    fields.append(
      journalSelect(cycle, note, 'setup', 'Setup type', [
        ['trend', 'Trend continuation'],
        ['breakout', 'Breakout / breakdown'],
        ['pullback', 'Pullback'],
        ['reversal', 'Reversal'],
        ['range', 'Range / mean reversion'],
        ['other', 'Other']
      ]),
      journalSelect(cycle, note, 'entryTrigger', 'Entry trigger', [
        ['close-break', 'Candle close beyond level'],
        ['retest', 'Break-and-retest'],
        ['vwap', 'VWAP reclaim / rejection'],
        ['support-resistance', 'Support / resistance reaction'],
        ['momentum', 'Momentum confirmation'],
        ['other', 'Other']
      ]),
      journalSelect(cycle, note, 'entryEmotion', 'Emotion at entry', [
        ['calm', 'Calm / patient'],
        ['confident', 'Confident'],
        ['hesitant', 'Hesitant'],
        ['fearful', 'Fearful'],
        ['fomo', 'FOMO / chasing'],
        ['frustrated', 'Frustrated'],
        ['revenge', 'Revenge impulse']
      ]),
      journalSelect(cycle, note, 'emotion', 'Emotion at exit', [
        ['calm', 'Calm'],
        ['confident', 'Confident'],
        ['hesitant', 'Hesitant'],
        ['fearful', 'Fearful'],
        ['greedy', 'Greedy'],
        ['fomo', 'FOMO'],
        ['frustrated', 'Frustrated'],
        ['revenge', 'Revenge']
      ]),
      journalSelect(cycle, note, 'exitReason', 'Exit reason', [
        ['target', 'Planned target reached'],
        ['stop', 'Planned stop hit'],
        ['trail', 'Trailing stop'],
        ['signal', 'Setup invalidated'],
        ['time', 'Time-based exit'],
        ['manual', 'Manual / other']
      ]),
      journalSelect(cycle, note, 'mistake', 'Execution / mistake tag', [
        ['none', 'No clear mistake'],
        ['late-entry', 'Late entry / chased'],
        ['early-exit', 'Exited too early'],
        ['oversized', 'Position too large'],
        ['moved-stop', 'Moved / skipped stop'],
        ['no-trigger', 'Entered without trigger'],
        ['overtrade', 'Overtrading'],
        ['revenge', 'Revenge trade'],
        ['other', 'Other']
      ]),
      journalSelect(cycle, note, 'plan', 'Followed written plan?', [
        ['yes', 'Yes'],
        ['no', 'No']
      ]),
      journalNumber(cycle, note, 'plannedStop', 'Planned stop (premium)'),
      journalNumber(cycle, note, 'plannedTarget', 'Planned target (premium)'),
      journalNumber(cycle, note, 'plannedRisk', 'Planned max loss (₹)'),
      journalText(cycle, note, 'note', 'Lesson / next-time action', 'What will I repeat or change?', 360)
    );
    review.appendChild(fields);
    reviewCell.appendChild(review);
    row.appendChild(reviewCell);
    tbody.appendChild(row);
  }

  if (!cycles.length) {
    const row = document.createElement('tr');
    const cell = document.createElement('td');
    cell.colSpan = 6;
    cell.className = 'table-empty';
    cell.textContent = 'No closed same-session F&O cycles are available. Open trades and any carried positions are not counted as closed cycles.';
    row.appendChild(cell);
    tbody.appendChild(row);
  }
  renderJournalInsights();
}

function renderTradingSummary(data) {
  tradingSummary = data;
  const cycles = Array.isArray(data.closedCycles) ? data.closedCycles : [];
  const pnl = Number(data.realizedPnl);
  const storedCharges = safeLocalRead(chargesStorageKey);
  const rawCharge = storedCharges[data.date];
  const validCharge = rawCharge !== undefined && rawCharge !== ''
    && Number.isFinite(Number(rawCharge)) && Number(rawCharge) >= 0;
  chargesInput.disabled = false;
  chargesInput.value = validCharge ? rawCharge : '';
  document.getElementById('charges-note').textContent =
    'Enter the actual total from your contract note; saved in this browser for this date.';
  setMetricValue('realized-pnl', formatRupees(pnl, true), pnl);
  const netPnl = validCharge && Number.isFinite(pnl) ? pnl - Number(rawCharge) : null;
  document.getElementById('net-pnl-label').textContent = 'Net P&L after charges';
  setMetricValue('net-pnl', netPnl === null ? '—' : formatRupees(netPnl, true), netPnl);
  setMetricValue('cycle-count', String(cycles.length));
  const wins = cycles.filter((cycle) => Number(cycle.realizedPnl) > 0);
  const losses = cycles.filter((cycle) => Number(cycle.realizedPnl) < 0);
  document.getElementById('win-loss-count').textContent = `Wins ${wins.length} · Losses ${losses.length}`;
  setMetricValue('win-rate', cycles.length ? `${((wins.length / cycles.length) * 100).toFixed(1)}%` : '—');
  const grossWins = wins.reduce((sum, cycle) => sum + Number(cycle.realizedPnl), 0);
  const grossLosses = Math.abs(losses.reduce((sum, cycle) => sum + Number(cycle.realizedPnl), 0));
  setMetricValue('profit-factor', grossLosses ? (grossWins / grossLosses).toFixed(2) : '—');
  const averageWin = wins.length ? grossWins / wins.length : null;
  const averageLoss = losses.length ? grossLosses / losses.length : null;
  document.getElementById('average-win-loss').textContent =
    `${averageWin === null ? '—' : formatRupees(averageWin)} / ${averageLoss === null ? '—' : `-${formatRupees(averageLoss)}`}`;
  const cyclePnl = cycles.reduce((sum, cycle) => sum + Number(cycle.realizedPnl), 0);
  setMetricValue('expectancy', cycles.length ? formatRupees(cyclePnl / cycles.length, true) : '—');
  let running = 0;
  let peak = 0;
  let maxDrawdown = 0;
  for (const cycle of [...cycles].sort((a, b) => new Date(a.exitTime) - new Date(b.exitTime))) {
    running += Number(cycle.realizedPnl);
    peak = Math.max(peak, running);
    maxDrawdown = Math.max(maxDrawdown, peak - running);
  }
  setMetricValue('max-drawdown', cycles.length ? formatRupees(-maxDrawdown) : '—');
  setMetricValue('fill-count', String(data.fillCount ?? 0));
  const openPositions = (data.positions || []).filter((position) => Number(position.quantity) !== 0);
  setMetricValue('open-positions', String(openPositions.length));
  document.getElementById('pnl-label').textContent = 'Groww realized P&L';
  const updated = data.updatedAt ? ` · Updated ${formatIndiaTime(data.updatedAt)} IST` : '';
  document.getElementById('trading-status').textContent =
    `Groww F&O session data for ${dateLabel(data.date)}${updated}. Realized P&L is from Groww; enter contract-note charges to calculate net P&L.`;
  renderTradeCycles(cycles);
}

function renderFutureSession(date) {
  tradingSummary = null;
  chargesInput.value = '';
  chargesInput.disabled = true;
  document.getElementById('charges-note').textContent = 'Future session; enter charges after the contract note is available.';
  ['realized-pnl', 'net-pnl', 'cycle-count', 'win-rate', 'profit-factor', 'average-win-loss', 'expectancy', 'max-drawdown', 'plan-adherence', 'fill-count', 'open-positions']
    .forEach((id) => setMetricValue(id, '—'));
  document.getElementById('pnl-label').textContent = 'Realized P&L';
  document.getElementById('net-pnl-label').textContent = 'Net P&L after charges';
  document.getElementById('win-loss-count').textContent = 'Wins — · Losses —';
  document.getElementById('trading-status').textContent =
    `${dateLabel(date)} is an upcoming session. Groww reports executions after they occur; future P&L and trades are not available.`;
  renderTradeCycles([]);
}

async function refreshTradingForSelectedDate(force = false) {
  const selectedDate = sessionDateSelect.value;
  const today = indiaDateString();
  if (!selectedDate) return;
  if (activeTab !== 'trading' && !force) return;
  if (selectedDate !== today) {
    renderFutureSession(selectedDate);
    return;
  }
  if (tradingRequestInProgress || (!force && tradingSummary?.date === today)) return;
  tradingRequestInProgress = true;
  document.getElementById('trading-status').textContent = 'Refreshing Groww F&O orders, fills, and positions…';
  try {
    const response = await fetch(`/api/trading?ts=${Date.now()}`, { cache: 'no-store' });
    const payload = await response.json();
    if (!response.ok) throw new Error(payload.error || `Groww trading-data request failed (${response.status}).`);
    renderTradingSummary(payload);
  } catch (error) {
    document.getElementById('trading-status').textContent =
      error instanceof Error ? error.message : 'Groww trading data is unavailable.';
    console.error('Groww trading-data refresh failed:', error);
  } finally {
    tradingRequestInProgress = false;
  }
}

function setStatus(status, message) {
  statusPill.dataset.state = status;
  updatedLabel.textContent = message;
}

function renderOiChange(payload) {
  oiChangeCards.replaceChildren();
  const changeData = payload.oiChange;
  if (!changeData) {
    oiChangeStatus.textContent = 'Groww has not returned an OI comparison yet.';
    return;
  }

  if (payload.testPreview) {
    oiChangeStatus.textContent = 'Synthetic preview only · all prices, OI, indicators, scores and expiries below are placeholders, not market data.';
  } else if (changeData.referenceTime) {
    oiChangeStatus.textContent = `OI change vs ${formatIndiaTime(changeData.referenceTime)} IST · ${changeData.windowMinutes}-minute window · net compares strikes present in both snapshots.`;
  } else if (changeData.availableAt) {
    oiChangeStatus.textContent = `Collecting in-memory OI snapshots · comparison available after ${formatIndiaTime(changeData.availableAt)} IST.`;
  } else {
    oiChangeStatus.textContent = 'OI change is compared with an earlier in-memory snapshot; it is not a standalone directional signal.';
  }

  for (const item of changeData.symbols || []) {
    const fragment = oiChangeTemplate.content.cloneNode(true);
    const analysis = item.tradeAnalysis || {};
    const marketItem = (payload.symbols || []).find((symbol) => symbol.symbol === item.symbol) || {};
    fragment.querySelector('.change-symbol').textContent = item.symbol || '—';
    fragment.querySelector('.change-spot-price').textContent =
      Number(marketItem.spotPrice) > 0 ? `₹${formatNumber(marketItem.spotPrice)}` : 'Spot unavailable';
    const expirySelect = fragment.querySelector('.expiry-select');
    const availableExpiries = Array.isArray(marketItem.availableExpiries) ? marketItem.availableExpiries : [];
    const selectedExpiry = payload.selectedExpiries?.[item.symbol] || marketItem.expiryDate || marketItem.expiry;
    selectedExpiries[item.symbol] = selectedExpiry;
    expirySelect.setAttribute('aria-label', `Choose ${item.symbol} option expiry`);
    expirySelect.dataset.symbol = item.symbol || '';
    expirySelect.replaceChildren();
    for (const expiry of availableExpiries) {
      const option = document.createElement('option');
      option.value = expiry;
      option.textContent = expiryOptionLabel(expiry, payload.testPreview);
      expirySelect.appendChild(option);
    }
    expirySelect.value = selectedExpiry;
    fragment.querySelector('.strike-range-label').textContent =
      `±${formatNumber(marketItem.strikeRangePoints)} pts`;
    const supertrend = analysis.supertrend;
    const fiveMinute = analysis.indicators?.fiveMinute || {};
    const fifteenMinute = analysis.indicators?.fifteenMinute || {};
    const marketContext = fragment.querySelector('.market-context');
    marketContext.replaceChildren();
    const emaAlignment = (indicators) => {
      if (indicators.ema20 === null || indicators.ema20 === undefined ||
          indicators.ema50 === null || indicators.ema50 === undefined) return '—';
      return indicators.ema20 > indicators.ema50 ? 'Bullish' :
        indicators.ema20 < indicators.ema50 ? 'Bearish' : 'Flat';
    };
    const marketChips = [
      ['Regime', analysis.regime || 'uncertain'],
      ['EMA 5m / 15m', `${emaAlignment(fiveMinute)} / ${emaAlignment(fifteenMinute)}`],
      ['RSI 5m / 15m', `${formatNumber(fiveMinute.rsi14)} / ${formatNumber(fifteenMinute.rsi14)}`],
      ['Supertrend', supertrend?.direction || '—'],
      ['PCR', Number.isFinite(Number(analysis.pcr)) ? formatNumber(analysis.pcr) : '—'],
      ['15m index', analysis.spotChange === null || analysis.spotChange === undefined
        ? '—'
        : `${formatSignedNumber(analysis.spotChange)} pts`]
    ];
    for (const [label, value] of marketChips) {
      const chip = document.createElement('span');
      chip.className = 'market-context-chip';
      chip.textContent = `${label} ${value}`;
      marketContext.appendChild(chip);
    }
    for (const sideName of ['call', 'put']) {
      const side = item[sideName];
      const prefix = sideName === 'call' ? '.call' : '.put';
      fragment.querySelector(`${prefix}-change-strike`).textContent = side?.largestIncrease
        ? `₹${formatNumber(side.largestIncrease.strike)}`
        : 'No increase';
      fragment.querySelector(`${prefix}-change-increase`).textContent = side?.largestIncrease
        ? formatSignedNumber(side.largestIncrease.change)
        : '—';
      const highestOi = marketItem[sideName] || {};
      fragment.querySelector(`${prefix}-highest-oi-strike`).textContent =
        highestOi.strike !== null && highestOi.strike !== undefined
          ? `₹${formatNumber(highestOi.strike)}`
          : '—';
      fragment.querySelector(`${prefix}-highest-oi`).textContent = formatNumber(highestOi.oi);
      fragment.querySelector(`${prefix}-net-change`).textContent = side
        ? formatSignedNumber(side.change)
        : '—';

      const candidate = analysis[sideName];
      const status = fragment.querySelector(`${prefix}-candidate-status`);
      status.textContent = candidate?.status || 'WAIT';
      status.classList.toggle('is-watch', candidate?.status === 'WATCH CANDIDATE');
      status.classList.toggle('is-strong', candidate?.status === 'STRONG CANDIDATE');
      status.classList.toggle('is-preview', candidate?.status === 'PREVIEW ONLY');
      status.classList.toggle('is-wait', !['WATCH CANDIDATE', 'STRONG CANDIDATE', 'PREVIEW ONLY'].includes(candidate?.status));
      const strike = Number(candidate?.strike);
      const optionSide = sideName === 'call' ? 'CE' : 'PE';
      fragment.querySelector(`${prefix}-candidate-detail`).textContent =
        Number.isFinite(strike) && strike > 0
          ? `${item.expiry} · ${formatNumber(strike)} ${optionSide} · ${candidate.moneyness || '—'}`
          : candidate?.reason || `No ${optionSide} strikes within ±${formatNumber(candidate?.strikeRangePoints)} points of spot.`;
      const score = Number(candidate?.score);
      const normalizedScore = Number.isFinite(score) ? Math.max(0, Math.min(100, score)) : 0;
      fragment.querySelector(`${prefix}-candidate-score`).textContent =
        Number.isFinite(score) ? formatNumber(score) : '—';
      const scoreMeter = fragment.querySelector(`${prefix}-candidate-score-meter-fill`);
      scoreMeter.style.width = `${normalizedScore}%`;
      scoreMeter.closest('[role="progressbar"]').setAttribute('aria-valuenow', String(normalizedScore));
      scoreMeter.closest('[role="progressbar"]').setAttribute(
        'aria-valuetext',
        Number.isFinite(score) ? `${formatNumber(score)} out of 100; research score, not probability` : 'Score unavailable',
      );
      const contractLink = fragment.querySelector(`${prefix}-candidate-link`);
      if (!payload.testPreview && Number.isFinite(strike) && strike > 0 && item.expiry && item.symbol) {
        const contractQuery = `${item.symbol} ${item.expiry} ${strike} ${optionSide}`;
        contractLink.href = `https://groww.in/search?q=${encodeURIComponent(contractQuery)}`;
        contractLink.setAttribute('aria-label', `Search Groww for ${contractQuery}`);
        contractLink.hidden = false;
      } else {
        contractLink.hidden = true;
        contractLink.removeAttribute('href');
      }
      const premiumChange = candidate?.premiumChangePercent;
      const candidateOiChange = candidate?.oiChange;
      const metricItems = [
        ['LTP', candidate?.ltp === null || candidate?.ltp === undefined ? '—' : `₹${formatNumber(candidate.ltp)}`],
        ['Prem', premiumChange === null || premiumChange === undefined ? '—' : `${formatSignedNumber(premiumChange)}%`],
        ['OI Δ', candidateOiChange === null || candidateOiChange === undefined ? '—' : formatSignedNumber(candidateOiChange)],
        ['Vol', formatNumber(candidate?.volume)],
        ['Δ', candidate?.delta === null || candidate?.delta === undefined ? '—' : formatNumber(candidate.delta)],
        ['Spread', candidate?.bidAskSpreadPercent === null || candidate?.bidAskSpreadPercent === undefined
          ? '—'
          : `${formatNumber(candidate.bidAskSpreadPercent)}%`]
      ];
      const flow = fragment.querySelector(`${prefix}-candidate-flow`);
      flow.replaceChildren();
      for (const [label, value] of metricItems) {
        const metric = document.createElement('span');
        metric.className = 'candidate-metric';
        const metricLabel = document.createElement('small');
        metricLabel.textContent = label;
        const metricValue = document.createElement('strong');
        metricValue.textContent = value;
        metric.append(metricLabel, metricValue);
        flow.appendChild(metric);
      }

      const breakdown = fragment.querySelector(`${prefix}-candidate-score-breakdown`);
      breakdown.replaceChildren();
      for (const [componentName, component] of Object.entries(candidate?.scoreComponents || {})) {
        const weight = Number(component.weight);
        const points = Number(component.score);
        const available = component.available === true && Number.isFinite(weight) && weight > 0;
        const ratio = available && Number.isFinite(points)
          ? Math.max(0, Math.min(100, (points / weight) * 100))
          : 0;
        const row = document.createElement('div');
        row.className = `score-factor${available ? '' : ' is-unavailable'}`;
        const label = document.createElement('span');
        label.className = 'score-factor-label';
        label.textContent = scoreFactorLabels[componentName] || componentName;
        label.title = component.detail || '';
        const bar = document.createElement('span');
        bar.className = 'score-factor-track';
        bar.setAttribute('aria-hidden', 'true');
        const fill = document.createElement('span');
        fill.className = 'score-factor-fill';
        fill.style.width = `${ratio}%`;
        bar.appendChild(fill);
        const pointsLabel = document.createElement('span');
        pointsLabel.className = 'score-factor-points';
        pointsLabel.textContent = available ? `${formatNumber(points)}/${formatNumber(weight)}` : 'N/A';
        row.title = component.detail || `${label.textContent}: ${pointsLabel.textContent}`;
        row.append(label, bar, pointsLabel);
        breakdown.appendChild(row);
      }

      const rejectionDetails = fragment.querySelector(`${prefix}-candidate-rejection-details`);
      const rejectionSummary = fragment.querySelector(`${prefix}-candidate-rejection-summary`);
      const rejectionList = fragment.querySelector(`${prefix}-candidate-rejection-list`);
      rejectionList.replaceChildren();
      const rejections = candidate?.rejections || [];
      rejectionDetails.hidden = rejections.length === 0;
      rejectionSummary.textContent = rejections.length
        ? `Why WAIT · ${rejections.length} ${rejections.length === 1 ? 'check' : 'checks'}`
        : candidate?.status === 'PREVIEW ONLY' ? 'Preview only · not a live signal' : 'No blocking checks reported';
      for (const rejection of rejections) {
        const line = document.createElement('li');
        line.textContent = rejection;
        rejectionList.appendChild(line);
      }

      const rankings = fragment.querySelector(`${prefix}-candidate-rankings`);
      rankings.replaceChildren();
      const alternatives = (candidate?.rankings || []).filter((ranked) => ranked.rank !== 1);
      const alternativesDetails = fragment.querySelector(`${prefix}-candidate-alternatives`);
      alternativesDetails.hidden = alternatives.length === 0;
      alternativesDetails.querySelector('summary').textContent = alternatives.length
        ? `Other ranked strikes · ${alternatives.length}`
        : 'No alternatives in range';
      for (const ranked of alternatives) {
        const line = document.createElement('li');
        const rankedStrike = Number(ranked.strike);
        const strikeLabel = Number.isFinite(rankedStrike) ? `${formatNumber(rankedStrike)} ${optionSide}` : 'Strike unavailable';
        line.textContent = `#${ranked.rank} ${strikeLabel} · ${formatNumber(ranked.score)}/100 · ${ranked.status}`;
        line.title = ranked.rejections?.join('; ') || '';
        rankings.appendChild(line);
      }
    }
    oiChangeCards.appendChild(fragment);
  }
}

function getIndiaMarketTime(date = new Date()) {
  const parts = Object.fromEntries(
    indiaClock.formatToParts(date).map(({ type, value }) => [type, value]),
  );
  return {
    weekday: parts.weekday,
    seconds: Number(parts.hour) * 3600 + Number(parts.minute) * 60 + Number(parts.second),
    date: indiaDateString(date),
  };
}

function isWithinRefreshWindow(date = new Date()) {
  const { weekday, seconds, date: indiaDate } = getIndiaMarketTime(date);
  return tradingWeekdays.has(weekday)
    && !holidays.has(indiaDate)
    && seconds >= marketOpenSeconds
    && seconds <= marketCloseSeconds;
}

function secondsUntilNextOpen(weekday, seconds, currentDate = indiaDateString()) {
  const [year, month, day] = currentDate.split('-').map(Number);
  for (let daysAhead = 1; daysAhead <= 370; daysAhead += 1) {
    const candidate = new Date(Date.UTC(year, month - 1, day + daysAhead)).toISOString().slice(0, 10);
    const candidateWeekday = new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', weekday: 'short' })
      .format(new Date(`${candidate}T12:00:00Z`));
    if (tradingWeekdays.has(candidateWeekday) && !holidays.has(candidate)) {
      return daysAhead * 24 * 60 * 60 - seconds + marketOpenSeconds;
    }
  }
  return 24 * 60 * 60;
}

function getNextRefreshDelay(now = new Date()) {
  const { weekday, seconds, date } = getIndiaMarketTime(now);
  const holiday = holidays.has(date);
  if (!tradingWeekdays.has(weekday) || holiday || seconds > marketCloseSeconds) {
    return secondsUntilNextOpen(weekday, seconds, date) * 1000;
  }
  if (seconds < marketOpenSeconds) {
    return (marketOpenSeconds - seconds) * 1000;
  }

  const nextSlot = marketOpenSeconds
    + (Math.floor((seconds - marketOpenSeconds) / refreshIntervalSeconds) + 1) * refreshIntervalSeconds;
  if (nextSlot <= marketCloseSeconds) {
    return (nextSlot - seconds) * 1000;
  }
  return secondsUntilNextOpen(weekday, seconds, date) * 1000;
}

function scheduleNextRefresh() {
  window.clearTimeout(refreshTimer);
  if (testPreviewMode) {
    setStatus('preview', 'Synthetic UI preview · no live data');
    notice.textContent = 'TEST PREVIEW ONLY — every displayed market value, OI change, indicator, score, and candidate is synthetic UI filler. This is not Groww data, historical market data, or a trading signal. Groww contract links are disabled.';
    notice.classList.add('test-preview-notice');
    notice.hidden = false;
    return;
  }

  const now = new Date();
  const { weekday, seconds, date } = getIndiaMarketTime(now);
  const isWeekday = tradingWeekdays.has(weekday);
  const isHoliday = holidays.has(date);
  const isMarketHours = isWeekday && !isHoliday && seconds >= marketOpenSeconds && seconds <= marketCloseSeconds;

  if (!isMarketHours) {
    const nextWeekday = secondsUntilNextOpen(weekday, seconds, date);
    const nextOpen = new Date(Date.now() + nextWeekday * 1000);
    const nextOpenLabel = new Intl.DateTimeFormat('en-IN', {
      timeZone: 'Asia/Kolkata',
      weekday: 'short',
      hour: '2-digit',
      minute: '2-digit',
      hourCycle: 'h23',
    }).format(nextOpen);
    const reason = isHoliday ? 'Market holiday' : 'Market closed';
    setStatus('closed', `${reason} · next refresh ${nextOpenLabel} IST`);
  }
  notice.textContent = calendarWarning
    ? `${calendarWarning} The refresh schedule is using weekdays only until the official holiday calendar is available.`
    : isHoliday
      ? `NSE market holiday: ${holidayData?.entries?.find((item) => item.date === date)?.description || 'trading closed'}.`
      : '';
  notice.hidden = notice.textContent === '';

  refreshTimer = window.setTimeout(async () => {
    if (isWithinRefreshWindow()) {
      await refresh();
    } else {
      scheduleNextRefresh();
    }
  }, getNextRefreshDelay(now));
}

function render(payload) {
  const isTestPreview = payload?.testPreview === true && payload?.source === 'test-preview';
  if (payload?.source !== 'groww' && !isTestPreview) {
    throw new Error('Unexpected data source: this dashboard accepts Groww data only, except for explicit test preview mode.');
  }
  const items = Array.isArray(payload?.symbols) ? payload.symbols : [];
  if (items.length === 0) {
    throw new Error('The data feed returned no index symbols.');
  }
  renderOiChange(payload);

  testPreviewMode = isTestPreview;
  document.getElementById('market-data-source').textContent = isTestPreview
    ? 'Synthetic UI preview only · not Groww data'
    : 'Groww live market data';
  document.getElementById('footer-data-source').textContent = isTestPreview
    ? 'Synthetic UI preview only · no market data'
    : 'Groww data · For information only, not investment advice';
  if (isTestPreview) {
    setStatus('preview', 'Synthetic UI preview · no live data');
    notice.textContent = 'TEST PREVIEW ONLY — every displayed market value, OI change, indicator, score, and candidate is synthetic UI filler. This is not Groww data, historical market data, or a trading signal. Groww contract links are disabled.';
    notice.classList.add('test-preview-notice');
    notice.hidden = false;
  } else {
    const timestamp = payload.lastUpdated ? new Date(payload.lastUpdated) : new Date();
    const time = timestamp.toLocaleTimeString('en-IN', {
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
    });
    setStatus('live', `Groww · ${time}`);
    notice.classList.remove('test-preview-notice');
    notice.hidden = true;
    notice.textContent = '';
  }
}

async function refresh() {
  if (requestInProgress) return;
  requestInProgress = true;
  refreshButton.disabled = true;
  setStatus('loading', 'Refreshing…');

  try {
    const query = new URLSearchParams({ ts: String(Date.now()) });
    for (const symbol of ['NIFTY', 'SENSEX']) {
      if (selectedExpiries[symbol]) query.set(`expiry_${symbol}`, selectedExpiries[symbol]);
    }
    const response = await fetch(`/api/oi?${query.toString()}`, { cache: 'no-store' });
    const payload = await response.json();
    if (!response.ok) {
      throw new Error(payload.error || `Data request failed (${response.status}).`);
    }

    render(payload);
  } catch (error) {
    setStatus('error', 'Feed unavailable');
    notice.textContent = error instanceof Error ? error.message : 'Could not load market data.';
    notice.hidden = false;
    console.error('Open-interest refresh failed:', error);
  } finally {
    requestInProgress = false;
    refreshButton.disabled = false;
    scheduleNextRefresh();
  }
}

refreshButton.addEventListener('click', refresh);
oiChangeCards.addEventListener('change', (event) => {
  if (!(event.target instanceof HTMLSelectElement) || !event.target.matches('.expiry-select')) return;
  const symbol = event.target.dataset.symbol;
  if (!symbol || !event.target.value) return;
  selectedExpiries[symbol] = event.target.value;
  refresh();
});
marketTab.addEventListener('click', () => {
  activeTab = 'market';
  marketTab.classList.add('is-active');
  tradingTab.classList.remove('is-active');
  marketTab.setAttribute('aria-selected', 'true');
  tradingTab.setAttribute('aria-selected', 'false');
  marketPanel.hidden = false;
  tradingPanel.hidden = true;
});
tradingTab.addEventListener('click', () => {
  activeTab = 'trading';
  tradingTab.classList.add('is-active');
  marketTab.classList.remove('is-active');
  tradingTab.setAttribute('aria-selected', 'true');
  marketTab.setAttribute('aria-selected', 'false');
  tradingPanel.hidden = false;
  marketPanel.hidden = true;
  refreshTradingForSelectedDate(true);
});
document.getElementById('trading-refresh-button').addEventListener('click', () => {
  refreshTradingForSelectedDate(true);
});
sessionDateSelect.addEventListener('change', () => {
  refreshTradingForSelectedDate(true);
});
chargesInput.addEventListener('input', () => {
  const selectedDate = sessionDateSelect.value;
  if (!selectedDate || selectedDate !== indiaDateString()) return;
  const chargeValue = chargesInput.value;
  if (chargeValue !== '' && (!Number.isFinite(Number(chargeValue)) || Number(chargeValue) < 0)) return;
  const savedCharges = safeLocalRead(chargesStorageKey);
  if (chargeValue === '') {
    delete savedCharges[selectedDate];
  } else {
    savedCharges[selectedDate] = chargeValue;
  }
  if (!safeLocalWrite(chargesStorageKey, savedCharges)) return;
  if (tradingSummary) renderTradingSummary(tradingSummary);
});
window.setInterval(() => {
  if (activeTab === 'trading' && sessionDateSelect.value === indiaDateString()) {
    refreshTradingForSelectedDate(true);
  }
}, tradingRefreshIntervalSeconds * 1000);
refreshHolidays();
refresh();
