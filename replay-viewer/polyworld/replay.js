'use strict';
(async () => {
  const canvas = document.getElementById('canvas'), slider = document.getElementById('seek');
  const play = document.getElementById('play'), status = document.getElementById('status');
  let module, ticks = 0, index = 0, playing = false, lastTime = 0, debt = 0;
  const fail = message => { playing = false; status.textContent = String(message); document.documentElement.dataset.replayError = String(message); };
  try {
    module = await RaidPolyworldModule({canvas, onAbort: fail});
    const response = await fetch('encounter.public.json', {signal:AbortSignal.timeout(15000)});
    if (!response.ok) throw Error('Replay HTTP ' + response.status);
    const bytes = new Uint8Array(await response.arrayBuffer()), pointer = module._malloc(bytes.length);
    module.HEAPU8.set(bytes, pointer);
    ticks = module._raid_pw_load(pointer, bytes.length);
    module._free(pointer);
    if (ticks <= 0) throw Error(module.UTF8ToString(module._raid_pw_error()));
    const decode = () => JSON.parse(new TextDecoder().decode(module.HEAPU8.slice(module._raid_pw_ptr(), module._raid_pw_ptr() + module._raid_pw_len())));
    const summary = decode();
    const inspect = tick => {
      if (module._raid_pw_inspect(tick) < 0) throw Error(module.UTF8ToString(module._raid_pw_error()));
      return decode();
    };
    const seek = tick => {
      index = Math.max(0, Math.min(ticks - 1, Math.floor(tick)));
      if (module._raid_pw_draw(index, canvas.width, canvas.height) < 0) throw Error(module.UTF8ToString(module._raid_pw_error()));
      const frame = decode(); slider.value = String(index);
      document.getElementById('tick').textContent = `${index} / ${ticks - 1}`;
      status.textContent = `Phase ${frame.scene.phase} · digest ${frame.digest} · ${summary.end_rule} at ${summary.terminal_tick} · score ${summary.score}`;
      return frame;
    };
    const pause = () => { playing = false; play.textContent = 'Play'; debt = 0; };
    const start = () => { if (index === ticks - 1) seek(0); playing = true; play.textContent = 'Pause'; lastTime = performance.now(); };
    const resize = () => {
      const rect = canvas.getBoundingClientRect();
      canvas.width = Math.max(1, Math.round(rect.width * devicePixelRatio));
      canvas.height = Math.max(1, Math.round(rect.height * devicePixelRatio));
      seek(index);
    };
    play.onclick = () => playing ? pause() : start();
    document.getElementById('restart').onclick = () => {pause(); seek(0);};
    document.getElementById('back').onclick = () => {pause(); seek(index - 24);};
    document.getElementById('forward').onclick = () => {pause(); seek(index + 24);};
    slider.max = String(ticks - 1); slider.oninput = () => {pause(); seek(Number(slider.value));};
    const animate = now => {
      if (playing) {
        debt += Math.min(250, now - lastTime) * 24 / 1000;
        const step = Math.floor(debt); debt -= step;
        if (step) {seek(index + step); if (index === ticks - 1) pause();}
      }
      lastTime = now; requestAnimationFrame(animate);
    };
    window.raidReplay = {inspect, seek, pause, start, summary,
      get index(){return index;}, get playing(){return playing;}, get tickCount(){return ticks;}};
    window.addEventListener('resize', resize); resize(); play.disabled = false;
    document.documentElement.dataset.replayLoaded = 'true'; requestAnimationFrame(animate);
    window.addEventListener('pagehide', event => {
      pause();
      if (!event.persisted) module._raid_pw_close();
    });
  } catch (error) {fail(error.message || error);}
})();
