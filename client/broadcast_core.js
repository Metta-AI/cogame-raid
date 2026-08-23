'use strict';
// broadcast_core.js — the raid board renderer. Runs inside the replay Worker
// on an OffscreenCanvas (and would run on a plain canvas unchanged), so it
// touches no DOM: the wasm canvas draws the WORLD (floor, pit rim, pillars,
// pools, telegraph decals, boss, adds, cogs, damage pops) and the page's DOM
// chrome draws the boss bar, nameplates, cast bar, enrage clock, feed,
// transport and endcard.
//
// One frame object per tick comes out of the wasm module:
//   {t, d, cogs:[[x,y,aim,hp,shield,mana,state] x5],
//    boss:[x,y,aim,hp,phase,feed,spill],
//    adds:[[id,x,y,hp]], pools:[[id,cx,cy,r,age]],
//    tel:[[id,kind,cx,cy,r_or_facing,fuse,soak]], mtr:[[dmg,adds,heal,taken]]}

(function (scope) {
  var ROLE_COLORS = {
    tank: '#4b7bec', healer: '#2ecc71',
    dps: ['#f2c14e', '#e8743b', '#a55eea']
  };
  var BOSS_COLOR = '#d63031';
  var ADD_COLOR = '#8d6e63';
  var ALIASES = ['Alpha', 'Bravo', 'Charlie', 'Delta', 'Echo'];
  var TEL_CLEAVE = 0, TEL_POUR = 1, TEL_CRUCIBLE = 2;
  var BRAD = Math.PI * 2 / 256;

  function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v); }

  function create(config) {
    var canvas = config.canvas;
    var ctx = canvas.getContext('2d', { alpha: false });
    var art = config.art || {};
    var meta = null;
    var map = null;
    var frame = null;
    var pops = [];
    var draws = 0;
    var viewport = {
      w: config.viewportWidth || 960,
      h: config.viewportHeight || 540,
      dpr: config.devicePixelRatio || 1
    };
    var view = { zoom: 1, focusX: 0, focusY: 0 };
    var minimap = null;
    var minimapCtx = null;

    function worldW() { return map ? map.width : 1235; }
    function worldH() { return map ? map.height : 659; }

    function transform() {
      var fit = Math.min(viewport.w / worldW(), viewport.h / worldH());
      var scale = fit * view.zoom;
      var visW = viewport.w / scale;
      var visH = viewport.h / scale;
      var fx = view.zoom <= 1 ? worldW() / 2 : clamp(view.focusX, visW / 2, worldW() - visW / 2);
      var fy = view.zoom <= 1 ? worldH() / 2 : clamp(view.focusY, visH / 2, worldH() - visH / 2);
      return {
        scale: scale, fitScale: fit, zoom: view.zoom,
        offsetX: viewport.w / 2 - fx * scale,
        offsetY: viewport.h / 2 - fy * scale,
        nativeW: worldW(), nativeH: worldH(),
        minZoom: 1, maxZoom: 6,
        focusX: fx, focusY: fy, visW: visW, visH: visH
      };
    }

    function reportTransform() {
      if (config.onTransform) config.onTransform(transform());
    }

    function setViewportSize(w, h, dpr) {
      viewport.w = Math.max(1, w || viewport.w);
      viewport.h = Math.max(1, h || viewport.h);
      viewport.dpr = dpr || viewport.dpr;
      canvas.width = Math.round(viewport.w * viewport.dpr);
      canvas.height = Math.round(viewport.h * viewport.dpr);
      reportTransform();
      draw();
    }

    function setMeta(next) {
      meta = next;
      map = (next && next.map) || null;
      view.focusX = worldW() / 2;
      view.focusY = worldH() / 2;
      reportTransform();
    }

    function roleColor(index) {
      if (!meta || !meta.names || !meta.names.roles) return '#f2e8d8';
      var role = meta.names.roles[index];
      if (role === 'tank') return ROLE_COLORS.tank;
      if (role === 'healer') return ROLE_COLORS.healer;
      var rank = 0;
      for (var i = 0; i < index; i++) {
        if (meta.names.roles[i] === 'dps') rank++;
      }
      return ROLE_COLORS.dps[rank % ROLE_COLORS.dps.length];
    }

    function addPop(x, y, text, color) {
      pops.push({ x: x, y: y, text: text, color: color, life: 24 });
      if (pops.length > 40) pops.shift();
    }

    function ingest(next) {
      var previous = frame;
      frame = next;
      if (previous && next && previous.t !== next.t) {
        for (var i = 0; i < next.cogs.length && i < previous.cogs.length; i++) {
          var lost = previous.cogs[i][3] - next.cogs[i][3];
          if (lost >= 20) {
            addPop(next.cogs[i][0], next.cogs[i][1] - 14, '-' + lost, '#ff8a6a');
          }
        }
      }
      draw();
    }

    function drawFloor(t) {
      ctx.fillStyle = '#120c09';
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      var cx = (map ? map.pit.cx : 617), cy = (map ? map.pit.cy : 329);
      var r = (map ? map.pit.r : 300);
      ctx.save();
      ctx.beginPath();
      ctx.arc(cx, cy, r, 0, Math.PI * 2);
      ctx.clip();
      if (art.floor) {
        ctx.drawImage(art.floor, cx - r, cy - r, r * 2, r * 2);
      } else {
        ctx.fillStyle = '#3a2a22';
        ctx.fillRect(cx - r, cy - r, r * 2, r * 2);
      }
      ctx.restore();
      ctx.lineWidth = 7;
      ctx.strokeStyle = '#6b4636';
      ctx.beginPath();
      ctx.arc(cx, cy, r, 0, Math.PI * 2);
      ctx.stroke();
    }

    function drawPillars() {
      if (!map || !map.pillars) return;
      for (var i = 0; i < map.pillars.length; i++) {
        var p = map.pillars[i];
        if (art.pillar) {
          ctx.drawImage(art.pillar, p.x, p.y, p.w, p.h);
        } else {
          ctx.fillStyle = '#5b463a';
          ctx.fillRect(p.x, p.y, p.w, p.h);
        }
        ctx.strokeStyle = '#20140f';
        ctx.lineWidth = 2;
        ctx.strokeRect(p.x, p.y, p.w, p.h);
      }
    }

    function drawPools() {
      if (!frame || !frame.pools) return;
      for (var i = 0; i < frame.pools.length; i++) {
        var pool = frame.pools[i];
        var fade = clamp(1 - pool[4] / 240, 0.25, 1);
        ctx.save();
        ctx.globalAlpha = 0.55 * fade;
        if (art.pool) {
          ctx.drawImage(art.pool, pool[1] - pool[3], pool[2] - pool[3],
            pool[3] * 2, pool[3] * 2);
        } else {
          ctx.fillStyle = '#c9541f';
          ctx.beginPath();
          ctx.arc(pool[1], pool[2], pool[3], 0, Math.PI * 2);
          ctx.fill();
        }
        ctx.restore();
      }
    }

    function drawTelegraphs() {
      if (!frame || !frame.tel) return;
      var bossX = frame.boss[0], bossY = frame.boss[1];
      for (var i = 0; i < frame.tel.length; i++) {
        var tel = frame.tel[i];
        var kind = tel[1];
        if (kind === TEL_CLEAVE) {
          var facing = tel[4] * BRAD;
          var half = 32 * BRAD;
          ctx.save();
          ctx.beginPath();
          ctx.moveTo(bossX, bossY);
          ctx.arc(bossX, bossY, 180, -facing - half, -facing + half);
          ctx.closePath();
          ctx.fillStyle = 'rgba(240,120,50,0.28)';
          ctx.fill();
          ctx.strokeStyle = '#ff9a55';
          ctx.lineWidth = 3;
          ctx.stroke();
          ctx.restore();
        } else {
          var white = kind === TEL_CRUCIBLE;
          var radius = tel[4];
          var fuse = tel[5];
          var total = white ? 72 : 60;
          var burned = clamp(1 - fuse / total, 0, 1);
          ctx.save();
          ctx.beginPath();
          ctx.arc(tel[2], tel[3], radius, 0, Math.PI * 2);
          ctx.fillStyle = white ? 'rgba(255,255,255,0.16)' : 'rgba(255,140,50,0.18)';
          ctx.fill();
          // fills from the EDGE inward as the fuse burns
          ctx.beginPath();
          ctx.arc(tel[2], tel[3], radius, 0, Math.PI * 2);
          ctx.arc(tel[2], tel[3], radius * (1 - burned), 0, Math.PI * 2, true);
          ctx.fillStyle = white ? 'rgba(255,255,255,0.4)' : 'rgba(255,120,40,0.45)';
          ctx.fill('evenodd');
          ctx.strokeStyle = white ? '#ffffff' : '#ff7a2a';
          ctx.lineWidth = 4;
          ctx.beginPath();
          ctx.arc(tel[2], tel[3], radius, 0, Math.PI * 2);
          ctx.stroke();
          if (art.ring) {
            ctx.globalAlpha = 0.7;
            ctx.drawImage(art.ring, tel[2] - radius, tel[3] - radius,
              radius * 2, radius * 2);
          }
          ctx.restore();
        }
      }
    }

    function drawBoss() {
      if (!frame) return;
      var b = frame.boss;
      var size = 128;
      if (art.boss) {
        ctx.save();
        ctx.globalAlpha = 1;
        ctx.drawImage(art.boss, b[0] - size / 2, b[1] - size / 2, size, size);
        ctx.restore();
      } else {
        ctx.fillStyle = BOSS_COLOR;
        ctx.fillRect(b[0] - 28, b[1] - 28, 56, 56);
      }
      // facing pip
      ctx.strokeStyle = '#ffd9c9';
      ctx.lineWidth = 3;
      ctx.beginPath();
      ctx.moveTo(b[0], b[1]);
      ctx.lineTo(b[0] + Math.cos(b[2] * BRAD) * 46, b[1] - Math.sin(b[2] * BRAD) * 46);
      ctx.stroke();
    }

    function drawAdds() {
      if (!frame || !frame.adds) return;
      for (var i = 0; i < frame.adds.length; i++) {
        var a = frame.adds[i];
        if (art.add) {
          ctx.drawImage(art.add, a[1] - 16, a[2] - 16, 32, 32);
        } else {
          ctx.fillStyle = ADD_COLOR;
          ctx.fillRect(a[1] - 8, a[2] - 8, 16, 16);
        }
        var hp = clamp(a[3] / 220, 0, 1);
        ctx.fillStyle = '#00000099';
        ctx.fillRect(a[1] - 12, a[2] - 20, 24, 3);
        ctx.fillStyle = '#c0553a';
        ctx.fillRect(a[1] - 12, a[2] - 20, 24 * hp, 3);
      }
    }

    function drawCogs() {
      if (!frame || !frame.cogs) return;
      for (var i = 0; i < frame.cogs.length; i++) {
        var c = frame.cogs[i];
        var dead = c[6] === 2;
        var role = meta && meta.names ? meta.names.roles[i] : 'dps';
        var sprite = role === 'tank' ? art.cogTank
          : (role === 'healer' ? art.cogHealer : art.cogDps);
        ctx.save();
        if (dead) ctx.globalAlpha = 0.35;
        // role tint: a ground ring under the wheels, so it never covers the kit
        ctx.strokeStyle = roleColor(i);
        ctx.lineWidth = 2.5;
        ctx.beginPath();
        ctx.ellipse(c[0], c[1] + 4, 14, 7, 0, 0, Math.PI * 2);
        ctx.stroke();
        if (!dead) {
          ctx.strokeStyle = '#f2e8d8aa';
          ctx.lineWidth = 2;
          ctx.beginPath();
          ctx.moveTo(c[0], c[1] + 4);
          ctx.lineTo(c[0] + Math.cos(c[2] * BRAD) * 20,
            c[1] + 4 - Math.sin(c[2] * BRAD) * 10);
          ctx.stroke();
        }
        if (sprite) {
          // the cog stands on (x, y): the sprite's feet sit on the ground ring
          ctx.drawImage(sprite, c[0] - 24, c[1] - 40, 48, 48);
        } else {
          ctx.fillStyle = roleColor(i);
          ctx.fillRect(c[0] - 6, c[1] - 6, 12, 12);
        }
        ctx.restore();
        // alias label: the board NEVER shows a real player name
        ctx.font = '11px "Courier New", monospace';
        ctx.textAlign = 'center';
        ctx.fillStyle = dead ? '#8d7a6a' : '#f2e8d8';
        ctx.fillText(ALIASES[i] || ('#' + i), c[0], c[1] - 44);
        if (c[4] > 0) {
          ctx.fillStyle = '#f2e8d8cc';
          ctx.fillRect(c[0] - 12, c[1] + 14, 24 * clamp(c[4] / 120, 0, 1), 3);
        }
      }
    }

    function drawPops() {
      ctx.font = 'bold 13px "Courier New", monospace';
      ctx.textAlign = 'center';
      for (var i = pops.length - 1; i >= 0; i--) {
        var pop = pops[i];
        ctx.globalAlpha = clamp(pop.life / 24, 0, 1);
        ctx.fillStyle = pop.color;
        ctx.fillText(pop.text, pop.x, pop.y - (24 - pop.life));
        ctx.globalAlpha = 1;
        pop.life -= 1;
        if (pop.life <= 0) pops.splice(i, 1);
      }
    }

    function drawMinimap(view3) {
      if (!minimapCtx || !frame) return;
      var mw = minimap.width, mh = minimap.height;
      minimapCtx.clearRect(0, 0, mw, mh);
      var s = Math.min(mw / worldW(), mh / worldH());
      minimapCtx.fillStyle = '#241a12';
      minimapCtx.fillRect(0, 0, mw, mh);
      minimapCtx.strokeStyle = '#6b4636';
      minimapCtx.beginPath();
      minimapCtx.arc((map ? map.pit.cx : 617) * s, (map ? map.pit.cy : 329) * s,
        (map ? map.pit.r : 300) * s, 0, Math.PI * 2);
      minimapCtx.stroke();
      for (var i = 0; i < frame.cogs.length; i++) {
        minimapCtx.fillStyle = roleColor(i);
        minimapCtx.fillRect(frame.cogs[i][0] * s - 2, frame.cogs[i][1] * s - 2, 4, 4);
      }
      minimapCtx.fillStyle = BOSS_COLOR;
      minimapCtx.fillRect(frame.boss[0] * s - 3, frame.boss[1] * s - 3, 6, 6);
      minimapCtx.strokeStyle = '#f2e8d8';
      minimapCtx.lineWidth = 1;
      minimapCtx.strokeRect(
        (view3.focusX - view3.visW / 2) * s, (view3.focusY - view3.visH / 2) * s,
        view3.visW * s, view3.visH * s);
    }

    function draw() {
      if (!frame) return;
      var view2 = transform();
      ctx.setTransform(viewport.dpr, 0, 0, viewport.dpr, 0, 0);
      ctx.fillStyle = '#120c09';
      ctx.fillRect(0, 0, viewport.w, viewport.h);
      ctx.save();
      ctx.translate(view2.offsetX, view2.offsetY);
      ctx.scale(view2.scale, view2.scale);
      drawFloor(frame.t);
      drawPools();
      drawTelegraphs();
      drawPillars();
      drawAdds();
      drawBoss();
      drawCogs();
      drawPops();
      ctx.restore();
      drawMinimap(view2);
      draws += 1;
      if (draws === 1 && config.onFirstFrame) config.onFirstFrame();
    }

    return {
      setMeta: setMeta,
      ingest: ingest,
      draw: draw,
      setViewportSize: setViewportSize,
      attachMinimap: function (surface) {
        minimap = surface;
        minimapCtx = surface ? surface.getContext('2d') : null;
      },
      zoomAt: function (factor) {
        view.zoom = clamp(view.zoom * factor, 1, 6);
        reportTransform(); draw();
      },
      setZoom: function (level) {
        view.zoom = clamp(level, 1, 6);
        reportTransform(); draw();
      },
      panBy: function (dx, dy) {
        var t = transform();
        view.focusX -= dx / t.scale;
        view.focusY -= dy / t.scale;
        reportTransform(); draw();
      },
      panByMap: function (dx, dy) {
        view.focusX += dx; view.focusY += dy; reportTransform(); draw();
      },
      panTo: function (x, y) {
        view.focusX = x; view.focusY = y; reportTransform(); draw();
      },
      resetView: function () {
        view.zoom = 1;
        view.focusX = worldW() / 2;
        view.focusY = worldH() / 2;
        reportTransform(); draw();
      },
      getTransform: transform,
      getPaceStats: function () {
        return { enabled: false, queued: 0, presented: draws, interval: 1000 / 24, draws: draws };
      },
      stop: function () { pops = []; }
    };
  }

  scope.RaidBroadcastCore = { create: create };
})(typeof self !== 'undefined' ? self : this);
