(function () {
  'use strict';

  var FETCH_TIMEOUT_MS = 20000;
  var failed = false;
  var scriptUrl = document.currentScript && document.currentScript.src;
  var workerUrl = new URL('./static_replay_worker.js', scriptUrl || location.href);

  // VIEWER -> HOST READINESS. An embedding page (the softmax.com theater, the
  // Observatory episode page) can only see this document's `load` event,
  // which fires long before the wasm module has compiled and the replay has
  // come back from S3. So the shell tells the parent what it is doing:
  // `loading` as soon as this script runs (before `load`, so the host never
  // mistakes document-load for a picture), `ready` once the renderer has
  // drawn its first frame, `error` when the replay cannot be shown. No
  // secrets ride on it, so the target origin is "*".
  function tell(type, message) {
    if (window.parent === window) return;
    var envelope = { src: 'coworld-replay', type: type };
    if (message) envelope.message = message;
    try { window.parent.postMessage(envelope, '*'); } catch (ignore) {}
  }
  tell('loading');

  function showFailure(error) {
    if (failed) return;
    failed = true;
    var message = (error && error.message) || String(error);
    var status = document.getElementById('status');
    if (status) {
      status.textContent = 'Replay failed: ' + message + ' ';
      status.classList.add('show');
      var retry = document.createElement('button');
      retry.id = 'loading-retry';
      retry.type = 'button';
      retry.textContent = 'Retry';
      retry.onclick = function () { location.reload(); };
      status.appendChild(retry);
    }
    document.documentElement.setAttribute('data-replay-error', message);
    tell('error', message);
  }

  function setMismatchTick(tick) {
    if (tick >= 0) {
      document.documentElement.setAttribute('data-replay-mismatch-tick', String(tick));
    }
  }

  function createCore(config) {
    var canvas = config.canvas;
    var worker = null;
    var started = false;
    var loaded = false;
    var advanceInFlight = false;
    var lastFrame = 0;
    var accumulator = 0;
    var frameMs = 1000 / 24;
    var speed = 1;
    var playing = true;
    var workerDraws = 0;
    var fetchTimer = null;
    var transform = {
      scale: 1, offsetX: 0, offsetY: 0, nativeW: 1, nativeH: 1,
      zoom: 1, minZoom: 1, maxZoom: 6, fitScale: 1,
      focusX: 0, focusY: 0, visW: 1, visH: 1
    };
    var viewport = { width: 1, height: 1, dpr: window.devicePixelRatio || 1 };
    var offscreen;
    var pendingMinimap = null;
    var minimapSent = false;

    function sendMinimap() {
      if (!worker || !pendingMinimap || minimapSent) return;
      if (typeof pendingMinimap.transferControlToOffscreen !== 'function') return;
      try {
        var surface = pendingMinimap.transferControlToOffscreen();
        minimapSent = true;
        pendingMinimap = null;
        worker.postMessage({ type: 'minimap', canvas: surface }, [surface]);
      } catch (error) {
        pendingMinimap = null;
      }
    }

    if (!canvas || typeof canvas.transferControlToOffscreen !== 'function') {
      showFailure(new Error('This browser does not support OffscreenCanvas Workers'));
    } else {
      try {
        offscreen = canvas.transferControlToOffscreen();
      } catch (error) {
        showFailure(error);
      }
    }

    function readViewport() {
      var rect = canvas.getBoundingClientRect();
      viewport = {
        width: Math.max(1, rect.width || canvas.clientWidth || 1),
        height: Math.max(1, rect.height || canvas.clientHeight || 1),
        dpr: window.devicePixelRatio || 1
      };
      return viewport;
    }

    function postViewport() {
      readViewport();
      if (worker && started) {
        worker.postMessage({
          type: 'resize', width: viewport.width,
          height: viewport.height, dpr: viewport.dpr
        });
      }
    }

    function animate(now) {
      if (failed || !loaded || !worker) return;
      if (!lastFrame) lastFrame = now;
      accumulator = Math.min(accumulator + Math.min(now - lastFrame, 250), 250);
      lastFrame = now;
      if (playing && !advanceInFlight && accumulator >= frameMs) {
        var frames = Math.min(64, Math.floor(accumulator / frameMs) * speed);
        accumulator -= Math.floor(accumulator / frameMs) * frameMs;
        advanceInFlight = true;
        worker.postMessage({ type: 'advance', frames: Math.max(1, frames) });
      }
      requestAnimationFrame(animate);
    }

    function onWorkerMessage(event) {
      if (failed) return;
      var message = event.data || {};
      try {
        if (message.type === 'meta') {
          if (config.onMeta) config.onMeta(message.meta);
        } else if (message.type === 'firstFrame') {
          // `ready` means a PICTURE, not merely a parsed payload: report it
          // one frame after the renderer's first blit.
          window.requestAnimationFrame(function () {
            window.requestAnimationFrame(function () { tell('ready'); });
          });
          if (config.onFirstFrame) config.onFirstFrame();
        } else if (message.type === 'transform') {
          transform = message.transform;
          if (config.onTransform) config.onTransform(transform);
        } else if (message.type === 'loaded') {
          if (fetchTimer) { window.clearTimeout(fetchTimer); fetchTimer = null; }
          setMismatchTick(message.mismatchTick);
          loaded = true;
          document.documentElement.setAttribute('data-replay-loaded', 'true');
          if (config.onLoaded) config.onLoaded(message);
          if (config.onFrame) config.onFrame(message.frame, 0);
          requestAnimationFrame(animate);
        } else if (message.type === 'advanced') {
          advanceInFlight = false;
          if (typeof message.draws === 'number') workerDraws = message.draws;
          if (config.onFrame) config.onFrame(message.frame, message.tick);
          if (message.atEnd && config.onEnd) config.onEnd();
        } else if (message.type === 'error') {
          showFailure(new Error(message.message || 'Replay Worker failed'));
          stop();
        }
      } catch (error) {
        showFailure(error);
      }
    }

    function start() {
      if (started || !offscreen || failed) return;
      started = true;
      var replayUrl = new URLSearchParams(location.search).get('replay');
      if (!replayUrl) {
        showFailure(new Error('missing required ?replay= URL'));
        return;
      }
      readViewport();
      // AbortController-equivalent for a worker-side fetch: bound the wait so
      // a dead CDN edge is not indistinguishable from a slow one.
      fetchTimer = window.setTimeout(function () {
        if (!loaded) {
          showFailure(new Error('replay fetch timed out after ' +
            Math.round(FETCH_TIMEOUT_MS / 1000) + 's'));
        }
      }, FETCH_TIMEOUT_MS);
      try {
        worker = new Worker(workerUrl, { name: 'raid-static-replay' });
        worker.onmessage = onWorkerMessage;
        worker.onerror = function (event) {
          showFailure(new Error(event.message || 'Replay Worker crashed'));
          stop();
        };
        worker.onmessageerror = function () {
          showFailure(new Error('Replay Worker sent an unreadable message'));
          stop();
        };
        worker.postMessage({
          type: 'init', replayUrl: replayUrl, canvas: offscreen,
          width: viewport.width, height: viewport.height, dpr: viewport.dpr
        }, [offscreen]);
        sendMinimap();
        document.documentElement.setAttribute('data-replay-worker', 'true');
      } catch (error) {
        showFailure(error);
      }
    }

    function stop() {
      if (!worker) return;
      worker.postMessage({ type: 'dispose' });
      worker.terminate();
      worker = null;
    }

    window.addEventListener('pagehide', stop, { once: true });

    return {
      start: start,
      stop: stop,
      seek: function (tick) { if (worker) worker.postMessage({ type: 'seek', tick: tick }); },
      setPlaying: function (value) { playing = !!value; },
      isPlaying: function () { return playing; },
      setSpeed: function (value) { speed = Math.max(1, value | 0); },
      getSpeed: function () { return speed; },
      zoomAt: function (factor, x, y) {
        if (worker) worker.postMessage({ type: 'view', action: 'zoom', factor: factor, x: x, y: y });
      },
      setZoom: function (level, x, y) {
        if (worker) worker.postMessage({ type: 'view', action: 'setZoom', level: level, x: x, y: y });
      },
      panBy: function (dx, dy) {
        if (worker) worker.postMessage({ type: 'view', action: 'pan', dx: dx, dy: dy });
      },
      panByMap: function (dx, dy) {
        if (worker) worker.postMessage({ type: 'view', action: 'panMap', dx: dx, dy: dy });
      },
      panTo: function (x, y) {
        if (worker) worker.postMessage({ type: 'view', action: 'panTo', x: x, y: y });
      },
      resetView: function () {
        if (worker) worker.postMessage({ type: 'view', action: 'reset' });
      },
      attachMinimap: function (surface) { pendingMinimap = surface || null; sendMinimap(); },
      getTransform: function () { return transform; },
      setViewportFit: postViewport,
      // The board draws a thread away, so `draws` mirrors the Worker core's
      // blit count and the page can still observe the real presentation rate.
      getPaceStats: function () {
        return { enabled: false, queued: 0, presented: 0, interval: frameMs, draws: workerDraws };
      }
    };
  }

  window.RaidStaticReplay = { createCore: createCore, tell: tell, showFailure: showFailure };
})();
