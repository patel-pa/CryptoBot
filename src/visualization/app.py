"""
CryptoBot — Streamlit Dashboard (Version 2 — merged live + historical chart)
============================================================================

A beginner-friendly dashboard for the CryptoBot project.

It does NOT touch the databases or the ML model directly. Instead it asks the
FastAPI backend (already built in src/api/main.py) for data over HTTP, then
draws that data on the page. Streamlit handles all the web/HTML/JS for us.

The main chart merges three things into ONE Binance-style candlestick view:
  • historical 1-minute candles      (from /charts  -> PostgreSQL)
  • live 1-minute candles forming now (from /stream -> Binance WebSocket)
  • the model's next-candle forecast  (from /predict -> model + MongoDB)

HOW TO RUN
----------
1. Start the API in one terminal:
       uvicorn src.api.main:app --reload
2. Start this dashboard in another terminal:
       streamlit run src/visualization/app.py
3. A browser tab opens automatically at http://localhost:8501

REQUIRES (install once):
       pip install streamlit plotly requests
"""

import json                          # to decode the JSON ticks the stream sends
import os                            # to read configuration (API_BASE) from the environment
import time                          # small back-off pause before reconnecting the stream
import threading                     # run the live stream in the background, off the UI thread

import requests                      # to call our FastAPI endpoints over HTTP
import pandas as pd                  # to hold the candle data in a table
import streamlit as st              # the dashboard framework
import plotly.graph_objects as go    # to draw an interactive candlestick chart
import websocket                     # websocket-client (sync) — same lib as stream_live.py

# --- Avoid a pandas 3.0 + pyarrow segfault --------------------------------
# pandas 3.0 defaults string columns to a PyArrow-backed dtype whose
# ArrowStringArray._from_sequence SEGFAULTS (pandas 3.0.3 + pyarrow 25.0.0)
# when we build the many dt.strftime() chart labels on every refresh — which
# crashed the whole dashboard process every ~30-60s. Forcing the classic
# numpy/object string backend sidesteps the broken PyArrow path entirely.
pd.set_option("future.infer_string", False)

# ---------------------------------------------------------------------------
# 0. CONFIGURATION
# ---------------------------------------------------------------------------
# Where the FastAPI backend is running. Read from the environment so it works
# both directly (defaults to localhost) and inside Docker (set to http://api:8000).
# When we move to AWS later, ONLY this value changes — the rest stays put.
API_BASE = os.getenv("API_BASE", "http://localhost:8000")

# The five columns every candle table uses, in the order the chart expects.
CANDLE_COLS = ["open_time", "open", "high", "low", "close"]

# st.set_page_config() must be the FIRST Streamlit call. It sets the browser
# tab title, the little icon, and uses the full page width.
st.set_page_config(page_title="CryptoBot Dashboard", page_icon="📈", layout="wide")

# --- Stop the page dimming on every auto-refresh ---------------------------
# While a (fragment) rerun runs, Streamlit greys out the not-yet-updated
# "stale" elements. Our chart refreshes every few seconds, so on a busy machine
# that grey-out reads as the whole screen flashing darker. Forcing stale
# elements to stay fully opaque makes each refresh visually seamless. The
# `transition: none` line also removes the fade animation so nothing flickers.
st.markdown(
    """
    <style>
      [data-stale="true"] { opacity: 1 !important; }
      .element-container, [data-testid="stVerticalBlock"] { transition: none !important; }
    </style>
    """,
    unsafe_allow_html=True,
)


# ---------------------------------------------------------------------------
# 1. HELPER FUNCTIONS — these talk to your API
# ---------------------------------------------------------------------------
# @st.cache_data remembers the result for `ttl` seconds, so re-runs within that
# window reuse the data instead of hammering the API.
@st.cache_data(ttl=10)
def fetch_charts(symbol: str, limit: int) -> pd.DataFrame:
    """GET /charts -> a DataFrame of recent historical candles (oldest first)."""
    response = requests.get(
        f"{API_BASE}/charts",
        params={"symbol": symbol, "limit": limit},   # becomes ?symbol=...&limit=...
        timeout=10,
    )
    response.raise_for_status()
    df = pd.DataFrame(response.json())
    # An empty DB (e.g. still backfilling, or just after `down -v`) returns [].
    # pd.DataFrame([]) has NO columns, so df["open_time"] would KeyError. Return
    # an empty-but-typed frame instead; the caller's `hist_df.empty` guard then
    # shows a friendly "still loading" message rather than crashing the page.
    if df.empty:
        return pd.DataFrame(columns=CANDLE_COLS)
    # open_time arrives as an ISO string — turn it into a real datetime.
    df["open_time"] = pd.to_datetime(df["open_time"])
    return df


# /predict is the expensive one: it loads the model, reads Mongo AND upserts the
# forecast. The upsert is keyed by target candle, so 6 calls/min store exactly
# the same history as 60 would — caching costs no data, only load.
@st.cache_data(ttl=10)
def fetch_prediction(symbol: str) -> float:
    """GET /predict -> the model's forecast for the next candle's close."""
    response = requests.get(f"{API_BASE}/predict", params={"symbol": symbol}, timeout=10)
    response.raise_for_status()
    return response.json()["predicted_next_close"]


# Joins up to 240 Mongo documents; the stored history only grows one row a minute.
@st.cache_data(ttl=30)
def fetch_predictions(symbol: str) -> list:
    """GET /predictions -> stored forecasts joined with each candle's actual close."""
    response = requests.get(
        f"{API_BASE}/predictions", params={"symbol": symbol, "limit": 240}, timeout=10
    )
    response.raise_for_status()
    return response.json()


def api_is_up() -> bool:
    """GET /health -> True if the backend answers, False if it's unreachable."""
    try:
        return requests.get(f"{API_BASE}/health", timeout=5).status_code == 200
    except requests.RequestException:
        return False


class LiveStreamer:
    """Owns ONE WebSocket to /stream on a background thread and keeps the latest tick.

    Why a background thread instead of reading the socket during each refresh?
    Streamlit re-runs the script (and our fragment) constantly. A socket stored
    in session_state did NOT survive those re-runs — every refresh reconnected a
    fresh connection, and a fresh connection has nothing buffered yet, so it
    always returned None. Result: the live candle never updated (0 collected).

    This thread instead stays connected for the life of the app, continuously
    reading ticks and stashing the newest one. Each UI refresh just reads that
    stashed value — instant, non-blocking, and always current. If the connection
    drops, the loop reconnects on its own after a short pause.

    Each Binance tick carries the full state of the in-progress 1-minute candle
    (open, high, low, close + start time), so one tick = the live candle's OHLC.
    """

    def __init__(self, ws_url: str):
        self.ws_url = ws_url
        self._latest = None                       # newest tick seen (a plain dict)
        self._lock = threading.Lock()             # guard reads/writes across threads
        thread = threading.Thread(target=self._run, daemon=True)
        thread.start()                            # daemon: dies automatically with the app

    def _run(self):
        """Reconnect-forever loop: read every tick and remember the latest."""
        while True:
            try:
                ws = websocket.create_connection(self.ws_url, timeout=5)
                while True:
                    tick = json.loads(ws.recv())  # blocks here until the next tick
                    with self._lock:
                        self._latest = tick
            except Exception:
                time.sleep(2)                     # dropped/unreachable — back off, retry

    def latest_tick(self):
        """Return the most recent tick (or None if none has arrived yet)."""
        with self._lock:
            return self._latest


# @st.cache_resource keeps ONE LiveStreamer alive across every re-run and browser
# session (unlike session_state, which failed to hold the live socket). The
# thread starts on first use and then simply keeps running.
@st.cache_resource
def get_streamer() -> LiveStreamer:
    ws_url = API_BASE.replace("http", "ws") + "/stream"   # http->ws (https->wss)
    return LiveStreamer(ws_url)


def read_latest_tick():
    """Return the freshest live tick from the background streamer (or None)."""
    return get_streamer().latest_tick()


# ---------------------------------------------------------------------------
# 2. SIDEBAR — the controls on the left
# ---------------------------------------------------------------------------
st.sidebar.header("Controls")
symbol = st.sidebar.selectbox("Symbol", ["BTCUSDT"])
limit = st.sidebar.slider("Historical candles to show", 20, 500, 100, step=10)
if st.sidebar.button("Refresh historical"):
    st.cache_data.clear()
    st.rerun()


# ---------------------------------------------------------------------------
# 3. HEADER + HEALTH GATE
# ---------------------------------------------------------------------------
st.title("CryptoBot — Live + Historical Price Chart")
st.caption("One candlestick view: historical candles, live forming candles, and the next-candle forecast.")

if not api_is_up():
    st.error(
        f"⚠️ Can't reach the API at {API_BASE}.\n\n"
        "Start it first with:  `uvicorn src.api.main:app --reload`"
    )
    st.stop()


# ---------------------------------------------------------------------------
# 4. FETCH HISTORICAL DATA (cached; refreshes via the sidebar button / slider)
# ---------------------------------------------------------------------------
hist_df = fetch_charts(symbol, limit)
if hist_df.empty:
    st.warning(
        "⏳ Historical candles are still loading. The backfill "
        "(`cryptobot-historical`) fetches the price history into the database "
        "the first time it runs — this can take a couple of minutes after a "
        "fresh start or a `docker compose down -v`. This page will fill in "
        "automatically; give it a minute, then press **R** to rerun."
    )
    st.stop()


# ---------------------------------------------------------------------------
# 5. THE MERGED LIVE CHART  (this whole block re-runs itself every 2 seconds)
# ---------------------------------------------------------------------------
# live_candles maps  kline_start_time -> {open_time, open, high, low, close}.
# Keying by start time means repeated ticks in the same minute keep updating
# the SAME candle, and a new minute simply adds a new key.
if "live_candles" not in st.session_state:
    st.session_state.live_candles = {}      # minute -> live OHLC candle


# These are 1-minute candles: a sub-second cadence redraws identical data while
# blocking the script thread, which starves Streamlit's browser connection.
@st.fragment(run_every="3s")
def merged_chart():
    # --- 1) pull the freshest live tick and fold it into its minute's candle -
    tick = read_latest_tick()
    if tick is not None:
        st.session_state.live_candles[tick["kline_start_time"]] = {
            "open_time": pd.to_datetime(tick["kline_start_time"]),
            "open": tick["open"], "high": tick["high"],
            "low": tick["low"], "close": tick["close"],
        }

    # --- 2) build the LIVE candle table (most recent 60 minutes) -------------
    live_candles = sorted(st.session_state.live_candles.values(),
                          key=lambda c: c["open_time"])
    live_df = pd.DataFrame(live_candles).tail(60)

    # --- 3) MERGE historical + live into one continuous table ----------------
    # keep="last" lets a live candle override a historical one for the same
    # minute, so the in-progress candle always wins.
    frames = [hist_df[CANDLE_COLS]]
    if not live_df.empty:
        frames.append(live_df[CANDLE_COLS])
    combined = (
        pd.concat(frames, ignore_index=True)
        .drop_duplicates(subset="open_time", keep="last")
        .sort_values("open_time")
        .reset_index(drop=True)
    )
    last_close = float(combined["close"].iloc[-1])

    # --- 4) METRICS row ------------------------------------------------------
    c1, c2, c3 = st.columns(3)
    c1.metric("Latest close", f"${last_close:,.2f}")

    predicted = None
    try:
        predicted = fetch_prediction(symbol)
        c2.metric("Predicted next close", f"${predicted:,.2f}",
                  delta=f"{predicted - last_close:,.2f}")
    except requests.RequestException:
        # /predict needs a recent candle in MongoDB (run stream_live.py to fill it).
        c2.metric("Predicted next close", "unavailable")
    c3.metric("Live candles collected", f"{len(live_df)}")

    # --- 5) DRAW the merged candlestick --------------------------------------
    # A CATEGORY x-axis packs candles side-by-side (like Binance/TradingView),
    # so any time gap in the data doesn't leave a big empty space on the chart.
    labels = combined["open_time"].dt.strftime("%m-%d %H:%M")

    fig = go.Figure()
    fig.add_trace(go.Candlestick(
        x=labels,
        open=combined["open"], high=combined["high"],
        low=combined["low"], close=combined["close"],
        # solid, bright candles (Binance colours) so they read clearly on dark bg
        increasing=dict(line=dict(color="#0ecb81"), fillcolor="#0ecb81"),
        decreasing=dict(line=dict(color="#f6465d"), fillcolor="#f6465d"),
        name=symbol,
    ))

    # --- 6) PREDICTION: dashed line + marker one candle into the FUTURE ------
    if predicted is not None:
        last_time = combined["open_time"].iloc[-1]
        pred_label = (last_time + pd.Timedelta(minutes=1)).strftime("%m-%d %H:%M")
        fig.add_trace(go.Scatter(
            x=[labels.iloc[-1], pred_label],
            y=[last_close, predicted],
            mode="lines+markers",
            line=dict(color="#f5b041", dash="dash"),
            marker=dict(size=11, symbol="diamond", color="#f5b041"),
            name="next-candle forecast",
        ))

    fig.update_layout(
        template="plotly_dark",
        paper_bgcolor="#0b0e11",           # Binance-like near-black background
        plot_bgcolor="#0b0e11",
        font=dict(color="#d1d4dc"),
        xaxis_type="category",             # gapless, evenly-spaced candles
        xaxis_rangeslider_visible=False,
        height=560,
        margin=dict(l=10, r=10, t=30, b=10),
        xaxis=dict(nticks=12, showgrid=True, gridcolor="#1c2127"),      # faint grid
        yaxis=dict(showgrid=True, gridcolor="#1c2127", side="right"),   # price on right
        legend=dict(orientation="h", y=1.04, x=0),
    )
    st.plotly_chart(fig, width="stretch")

    # --- 7) PREDICTED vs ACTUAL close — persistent history from the backend --
    # Forecasts are stored in MongoDB by the API and joined with each candle's
    # real close once it lands. So this is TRUE history that survives page
    # reloads and restarts — not just this browser session.
    st.subheader("Predicted vs actual close (stored history)")
    try:
        preds = fetch_predictions(symbol)
    except requests.RequestException:
        preds = []

    if len(preds) < 2:
        st.info("Building prediction history… it fills in as candles close.")
    else:
        pdf = pd.DataFrame(preds)
        pdf["target_time"] = pd.to_datetime(pdf["target_time"])
        pdf = pdf.set_index("target_time").sort_index()

        # Use a CATEGORY x-axis (same as the candlestick chart above): each
        # timestamp becomes an evenly-spaced slot instead of a real point in
        # time. Idle periods (e.g. days with no data) collapse away, so the
        # points pack side-by-side with no huge empty stretch — and no
        # misleading straight line bridging the gap.
        labels = pdf.index.strftime("%m-%d %H:%M")

        # Plotly (not st.line_chart) so the y-axis auto-zooms to the price range
        # instead of forcing 0 — otherwise the lines look flat near the top.
        # connectgaps=False keeps the green line broken where actual_close is
        # still missing (recent candles that haven't closed yet).
        fig2 = go.Figure()
        fig2.add_trace(go.Scatter(
            x=labels, y=pdf["actual_close"], mode="lines", connectgaps=False,
            name="actual", line=dict(color="#0ecb81"),
        ))
        fig2.add_trace(go.Scatter(
            x=labels, y=pdf["predicted_close"], mode="lines", connectgaps=False,
            name="predicted", line=dict(color="#f5b041", dash="dot"),
        ))
        fig2.update_layout(
            template="plotly_dark",
            paper_bgcolor="#0b0e11", plot_bgcolor="#0b0e11",
            font=dict(color="#d1d4dc"),
            height=320,
            margin=dict(l=10, r=10, t=10, b=10),
            xaxis_type="category",             # gapless, evenly-spaced slots
            xaxis=dict(nticks=12, showgrid=True, gridcolor="#1c2127"),
            yaxis=dict(showgrid=True, gridcolor="#1c2127", side="right"),
            legend=dict(orientation="h", y=1.12, x=0),
        )
        st.plotly_chart(fig2, width="stretch")
        # Error metrics over candles whose actual close is already known.
        paired = pdf.dropna(subset=["actual_close"])
        if not paired.empty:
            diff = paired["predicted_close"].iloc[-1] - paired["actual_close"].iloc[-1]
            mae = (paired["predicted_close"] - paired["actual_close"]).abs().mean()
            e1, e2 = st.columns(2)
            e1.metric("Latest error (predicted − actual)", f"${diff:,.2f}")
            e2.metric("Avg abs error", f"${mae:,.2f}")


merged_chart()   # call once; the fragment keeps itself refreshing every 2s


# ---------------------------------------------------------------------------
# 6. RAW DATA (collapsible) — the historical candles behind the chart
# ---------------------------------------------------------------------------
with st.expander("Show raw historical candle data"):
    st.dataframe(hist_df[::-1], width="stretch")
