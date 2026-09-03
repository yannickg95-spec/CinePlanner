(function () {
  function qsa(sel, ctx) { return Array.prototype.slice.call((ctx || document).querySelectorAll(sel)); }
  var q = document.getElementById('q');
  var clearq = document.getElementById('clearq');
  var countEl = document.getElementById('count');
  var resetEl = document.getElementById('reset');
  var toggleAll = document.getElementById('toggleall');
  var chips = qsa('.chip');
  var active = { type: null, time: null, media: false };
  // Episodes live in one page; a series switches which is shown (feature = 1).
  var episodeEls = qsa('.episode');
  var current = 0;
  var daysView = false;
  function ep() { return episodeEls[current]; }

  // Reveal the filter bar only now that we know scripting is available.
  var toolbarEl = document.getElementById('toolbar');
  toolbarEl.hidden = false;

  // Keep --sticky in step with the real toolbar height. On narrow phones the
  // toolbar wraps to two rows and grows past its 60px default; without this
  // the stuck "Day N" header tucks under it and its top text is clipped.
  function syncSticky() {
    var h = toolbarEl.offsetHeight;
    if (h > 0) document.documentElement.style.setProperty('--sticky', h + 'px');
  }
  syncSticky();
  window.addEventListener('resize', syncSticky);
  window.addEventListener('orientationchange', function () { setTimeout(syncSticky, 200); });

  // Shooting-day view: built on demand by cloning scene cards per the episode's
  // schedule, so scenes split across days show whole (off-day shots greyed out).
  var uid = 0;
  // Shooting-day view for one episode: clone its scene cards per its schedule.
  function buildDays(epEl, idx) {
    if (epEl.dataset.daysBuilt) return;
    epEl.dataset.daysBuilt = '1';
    var container = epEl.querySelector('.view-days');
    var sceneNodes = qsa('.view-scenes .scene', epEl);
    var schedule = (CP_EPISODES[idx] && CP_EPISODES[idx].schedule) || [];
    schedule.forEach(function (day) {
      var sec = document.createElement('section');
      sec.className = 'day-group';
      sec.id = 'day-' + day.n;
      if (day.iso) sec.setAttribute('data-date', day.iso);
      if (day.iso && day.iso === todayISO()) sec.classList.add('is-today');
      var h = document.createElement('div');
      h.className = 'day-title';
      h.innerHTML = '<span class="day-n">Day ' + day.n + '</span>' +
        (day.date ? '<span class="day-date">' + day.date + '</span>' : '') +
        (day.iso && day.iso === todayISO() ? '<span class="today-badge">Today</span>' : '');
      if (day.sunrise) {
        var tags = document.createElement('div');
        tags.className = 'sun-tags';
        function tag(label, val, golden) {
          return '<span class="sun-tag' + (golden ? ' golden' : '') + '">' +
            '<b>' + label + '</b>' + val + '</span>';
        }
        tags.innerHTML =
          tag('Sunrise', day.sunrise, false) +
          tag('Golden', day.goldenAM, true) +
          tag('Golden', day.goldenPM, true) +
          tag('Sunset', day.sunset, false);
        h.appendChild(tags);
      }
      sec.appendChild(h);
      var meta = document.createElement('div');
      meta.className = 'day-meta';
      meta.textContent = day.setups + ' scene' + (day.setups === 1 ? '' : 's') +
        ' · ' + day.shots + ' shot' + (day.shots === 1 ? '' : 's');
      sec.appendChild(meta);
      if (day.notes) {
        var note = document.createElement('div');
        note.className = 'day-note';
        note.textContent = day.notes;
        sec.appendChild(note);
      }
      if (!day.entries.length) {
        var p = document.createElement('p'); p.className = 'empty';
        p.textContent = 'No scenes scheduled.'; sec.appendChild(p);
      }
      day.entries.forEach(function (entry) {
        var src = sceneNodes[entry.s];
        if (!src) return;
        var node = src.cloneNode(true);
        node.removeAttribute('id');
        uid++;
        // Re-id the pure-CSS expand checkboxes so their labels still toggle.
        Array.prototype.forEach.call(node.querySelectorAll('.shot-toggle'), function (box) {
          var lab = node.querySelector('label[for="' + box.id + '"]');
          var newId = box.id + '-d' + uid;
          box.id = newId;
          if (lab) lab.setAttribute('for', newId);
        });
        // Optional strip note under the scene heading.
        if (entry.note) {
          var nb = document.createElement('div');
          nb.className = 'strip-note';
          nb.textContent = entry.note;
          var head = node.querySelector('.scene-head');
          if (head && head.nextSibling) node.insertBefore(nb, head.nextSibling);
          else node.appendChild(nb);
        }
        // Grey the shots not scheduled for this day.
        if (!entry.all) {
          var wanted = {};
          entry.shots.forEach(function (n) { wanted[n] = true; });
          Array.prototype.forEach.call(node.querySelectorAll('.shot'), function (shot) {
            var numEl = shot.querySelector('.shot-num');
            var num = numEl ? numEl.textContent.trim() : '';
            if (!wanted[num]) {
              shot.classList.add('shot-off');
              var main = shot.querySelector('.shot-main');
              if (main) {
                var msg = document.createElement('span');
                msg.className = 'shot-off-msg';
                msg.textContent = 'Not scheduled for this day';
                main.appendChild(msg);
              }
            }
          });
        }
        sec.appendChild(node);
      });
      container.appendChild(sec);
    });
  }

  function todayISO() {
    var d = new Date();
    function p(n) { return (n < 10 ? '0' : '') + n; }
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
  }
  function scrollToToday(epEl) {
    var el = epEl.querySelector('.view-days [data-date="' + todayISO() + '"]');
    if (!el) return;
    // Land the day header flush under the sticky toolbar (scrollIntoView would
    // add the day-group's scroll-margin, stopping short of the header).
    requestAnimationFrame(function () {
      var sticky = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--sticky')) || 0;
      var y = window.scrollY + el.getBoundingClientRect().top - sticky;
      window.scrollTo({ top: Math.max(0, y) });
    });
  }

  var vtScenes = document.getElementById('vt-scenes');
  var vtDays = document.getElementById('vt-days');
  var viewtoggle = document.getElementById('viewtoggle');
  // Show the active episode in the chosen view; hide the day switch for an
  // episode that has no shooting schedule.
  function applyView() {
    var epEl = ep();
    var hasDays = epEl.getAttribute('data-has-days') === '1';
    if (viewtoggle) viewtoggle.hidden = !hasDays;
    var days = daysView && hasDays;
    if (days) buildDays(epEl, current);
    epEl.querySelector('.view-scenes').hidden = days;
    epEl.querySelector('.view-days').hidden = !days;
    document.body.classList.toggle('days-mode', days);
    // The toolbar shrinks in day view (search/chips hidden) — re-measure so
    // --sticky (the sticky day-header offset and the scroll target) is right.
    syncSticky();
    if (vtScenes) vtScenes.classList.toggle('on', !days);
    if (vtDays) vtDays.classList.toggle('on', days);
    if (days) scrollToToday(epEl);
  }
  function setView(days) { daysView = days; applyView(); }
  if (vtDays) vtDays.addEventListener('click', function () { setView(true); });
  if (vtScenes) vtScenes.addEventListener('click', function () { setView(false); });

  function tocFor(id) {
    var items = qsa('.toc-item');
    for (var i = 0; i < items.length; i++) {
      if (items[i].getAttribute('data-for') === id) return items[i];
    }
    return null;
  }

  function apply() {
    var term = q.value.trim().toLowerCase();
    var shownScenes = 0, shownShots = 0, totalShots = 0;
    var scenes = qsa('.view-scenes .scene', ep());

    scenes.forEach(function (scene) {
      var isInt = scene.getAttribute('data-int') === '1';
      var isDay = scene.getAttribute('data-day') === '1';
      var sceneText = scene.getAttribute('data-text') || '';
      var sceneMatches = term === '' || sceneText.indexOf(term) !== -1;

      // Scene-level filters
      var passes = true;
      if (active.type === 'int' && !isInt) passes = false;
      if (active.type === 'ext' && isInt) passes = false;
      if (active.time === 'day' && !isDay) passes = false;
      if (active.time === 'night' && isDay) passes = false;

      var shots = Array.prototype.slice.call(scene.querySelectorAll('.shot'));
      totalShots += shots.length;
      var visibleHere = 0;

      shots.forEach(function (shot) {
        var ok = passes;
        if (ok && active.media && shot.getAttribute('data-media') !== '1') ok = false;
        // A scene matching by name shows all of its shots; otherwise the
        // shot has to match the term itself.
        if (ok && term !== '' && !sceneMatches) {
          var shotText = shot.getAttribute('data-text') || '';
          if (shotText.indexOf(term) === -1) ok = false;
        }
        shot.hidden = !ok;
        if (ok) visibleHere++;
      });

      // Keep an empty scene visible only when nothing shot-specific is filtering.
      var shotFilterActive = active.media || term !== '';
      var show = passes && (visibleHere > 0 || (!shotFilterActive && shots.length === 0) ||
                            (sceneMatches && !active.media && shots.length === 0));
      scene.hidden = !show;

      var item = tocFor(scene.id);
      if (item) item.hidden = !show;

      if (show) { shownScenes++; shownShots += visibleHere; }
    });

    var filtering = term !== '' || active.type || active.media || active.time;
    // The unfiltered total lives in the masthead subtitle; here we only show
    // the match count while filtering.
    countEl.textContent = filtering
      ? shownScenes + ' of ' + scenes.length + ' scenes · ' + shownShots + ' of ' + totalShots + ' shots'
      : '';
    resetEl.hidden = !filtering;
    clearq.hidden = term === '';
    var nr = ep().querySelector('.noresults');
    if (nr) nr.hidden = shownScenes !== 0;
  }

  q.addEventListener('input', apply);
  clearq.addEventListener('click', function () { q.value = ''; apply(); q.focus(); });

  chips.forEach(function (chip) {
    chip.addEventListener('click', function () {
      var group = chip.getAttribute('data-group');
      var value = chip.getAttribute('data-value');
      if (group === 'media') {
        active.media = !active.media;
      } else {
        active[group] = active[group] === value ? null : value;
      }
      chips.forEach(function (other) {
        var g = other.getAttribute('data-group');
        var v = other.getAttribute('data-value');
        var on = g === 'media' ? active.media : active[g] === v;
        other.classList.toggle('on', on);
      });
      apply();
    });
  });

  resetEl.addEventListener('click', function () {
    q.value = '';
    active = { type: null, time: null, media: false };
    chips.forEach(function (c) { c.classList.remove('on'); });
    apply();
  });

  // Individual scenes collapse natively via <details>; this only does all
  // of them at once, within the active episode.
  toggleAll.addEventListener('click', function () {
    var collapse = toggleAll.textContent.indexOf('Collapse') === 0;
    qsa('.view-scenes .scene', ep()).forEach(function (s) { s.open = !collapse; });
    toggleAll.textContent = collapse ? 'Expand all' : 'Collapse all';
  });

  // Update the subtitle and Director/Cinematographer credits to the active
  // episode (Production Company stays put). Only used when there's a switch.
  function esch(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
  function updateMasthead() {
    var el = ep();
    var subEl = document.getElementById('masthead-sub');
    if (subEl) subEl.textContent = el.getAttribute('data-sub') || '';
    var creditsEl = document.getElementById('credits');
    if (creditsEl) {
      var html = '';
      function span(label, val) {
        if (val && val.trim()) html += '<span class="credit"><b>' + label + '</b> ' + esch(val) + '</span>';
      }
      span('Production Company', creditsEl.getAttribute('data-company') || '');
      span('Director', el.getAttribute('data-director') || '');
      span('Cinematographer', el.getAttribute('data-cinematographer') || '');
      creditsEl.innerHTML = html;
    }
  }

  // Episode switch: swap which episode is shown, keeping search/filters/view.
  var epButtons = qsa('.ep-btn');
  function setEpisode(i) {
    if (i === current || !episodeEls[i]) return;
    current = i;
    episodeEls.forEach(function (el, idx) { el.hidden = idx !== i; });
    epButtons.forEach(function (b) {
      b.classList.toggle('on', parseInt(b.getAttribute('data-ep'), 10) === i);
    });
    toggleAll.textContent = 'Collapse all';
    updateMasthead();
    applyView();
    apply();
    window.scrollTo({ top: 0 });
  }
  epButtons.forEach(function (b) {
    b.addEventListener('click', function () { setEpisode(parseInt(b.getAttribute('data-ep'), 10)); });
  });

  // Enlarging a thumbnail is pure <details> — no script involved, so it
  // works in previews with JavaScript disabled. Script only adds the
  // niceties: one open at a time, and stopping a video when it closes.
  var mediaItems = qsa('.mi');
  mediaItems.forEach(function (item) {
    item.addEventListener('toggle', function () {
      if (item.open) {
        mediaItems.forEach(function (other) { if (other !== item) other.open = false; });
      } else {
        var video = item.querySelector('video');
        if (video) video.pause();
      }
    });
  });

  // Highlight the scene currently on screen in the index
  if ('IntersectionObserver' in window) {
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        var item = tocFor(entry.target.id);
        if (!item) return;
        if (entry.isIntersecting) {
          qsa('.toc-item').forEach(function (i) { i.classList.remove('active'); });
          item.classList.add('active');
        }
      });
    }, { rootMargin: '-70px 0px -70% 0px' });
    qsa('.view-scenes .scene').forEach(function (s) { observer.observe(s); });
  }

  var totop = document.getElementById('totop');
  window.addEventListener('scroll', function () { totop.hidden = window.scrollY < 500; });
  totop.addEventListener('click', function () { window.scrollTo({ top: 0, behavior: 'smooth' }); });

  document.addEventListener('keydown', function (event) {
    if (event.key === '/' && document.activeElement !== q) { event.preventDefault(); q.focus(); }
    if (event.key === 'Escape') {
      var open = document.querySelector('.mi[open]');
      if (open) { open.open = false; }
      else if (document.activeElement === q) { q.value = ''; apply(); }
    }
  });

  applyView();
  apply();
})();
