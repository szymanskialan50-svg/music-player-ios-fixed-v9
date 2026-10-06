const fs = require('fs');
let content = fs.readFileSync('c:/Users/xalan/Downloads/MoonDlc_Extracted/music-player-ios-ready/public/player.html', 'utf8');

content = content.replace(
  /<span style="font-size:15.5px;font-weight:500" data-i18n="profanity_filter">Profanity Filter \\(Blur bad words\\)<\/span>\\s*<input type="checkbox" id="profanityFilterToggle" style="transform:scale\\(1.2\\)">/g,
  \<span style="font-size:15.5px;font-weight:500" data-i18n="profanity_filter">Wycisz przekleñstwa</span>
            <select id="profanitySelect" style="background:var(--surface); color:var(--text); border:1px solid var(--border); border-radius:8px; padding:4px 8px; font-size:14px; outline:none;">
              <option value="off">Wy³¹czone</option>
              <option value="blur">Ukryj w tekœcie</option>
              <option value="mute">Wycisz w piosence</option>
              <option value="both">Ukryj i wycisz</option>
            </select>\
);

content = content.replace(
  /<button id="npClose" class="icon-btn np-close" aria-label="Close">\\s*<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2.3" stroke-linecap="round"><path d="M18 15l-6-6-6 6"\\/><\\/svg>\\s*<\\/button>/g,
  \<button id="npClose" class="icon-btn np-close" aria-label="Close">
    <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2.3" stroke-linecap="round"><path d="M18 15l-6-6-6 6"/></svg>
  </button>
  <button id="npHideLyrics" class="icon-btn np-close" style="left:auto; right:20px;" aria-label="Toggle Lyrics">
    <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2.3" stroke-linecap="round"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>
  </button>\
);

content = content.replace(
  /<div id="lyricOffsetControls"[\\s\\S]*?<\\/div>/,
  \<div id="lyricOffsetControls" style="display:none;"></div>\
);

content = content.replace(
  /const BAD_WORDS = \\['fuck'[\\s\\S]*?\\}\\s*\\}\\n/m,
  \const BAD_WORDS = ['fuck', 'fucking', 'bitch', 'shit', 'cunt', 'dick', 'pussy', 'kurwa', 'kurw', 'jeb', 'jebany', 'jebana', 'spierdala', 'chuj', 'cipa', 'dziwka', 'suka', 'pierdol', 'asshole', 'jeba', 'jebaæ', 'jebn¹æ', 'jebi¹', 'jebie', 'kurwy', 'kurw¹', 'kurwie', 'kurwom', 'pierdolê', 'pierdole', 'pierdolisz', 'pierdoli', 'spierdalaj', 'chuju', 'zajebi', 'zajebist'];
function getProfanitySetting() { return localStorage.getItem('mp_profanity_setting') || (localStorage.getItem('mp_profanity_filter') === 'true' ? 'blur' : 'off'); }
function hasProfanity(text) { if (!text) return false; const regex = new RegExp(\\\(?:^|[^\\\\\\\\p{L}])(\\\)\\\\\\\\p{L}*(?=[^\\\\\\\\p{L}]|$)\\\, 'giu'); return regex.test(text); }
function applyProfanityFilter(text) {
  const setting = getProfanitySetting();
  if (setting === 'off' || setting === 'mute') return text;
  if (!text) return text;
  const regex = new RegExp(\\\(?:^|[^\\\\\\\\p{L}])(\\\)\\\\\\\\p{L}*(?=[^\\\\\\\\p{L}]|$)\\\, 'giu');
  return text.replace(regex, (match, p1) => {
    const word = match.slice(p1.length);
    if (word.length <= 2) return match;
    return p1 + word[0] + '*'.repeat(word.length - 2) + word.slice(-1);
  });
}
\
);

content = content.replace(
  /const pfToggle = document\\.getElementById\\('profanityFilterToggle'\\);[\\s\\S]*?\\}\\);\\s*\\}/m,
  \const pfSelect = document.getElementById('profanitySelect');
  if(pfSelect) {
    pfSelect.value = getProfanitySetting();
    pfSelect.addEventListener('change', e => {
      localStorage.setItem('mp_profanity_setting', e.target.value);
      renderLibrary(); renderPlaylists();
      if (getCur()) updNPInfo(getCur());
    });
  }\
);

content = content.replace(
  /function setupAudio\\(\\)\\{[\\s\\S]*?\\}\\n/m,
  \unction setupAudio(){
  // Disabled audioCtx initialization to prevent 0.5s audio stutter on iOS backgrounding
  audioCtx=null; analyser=null; srcNode=null; freqData=null;
}\\n\
);

content = content.replace(
  /function updateLyricsSync\\(currentTime\\)\\{[\\s\\S]*?\\}\\n/m,
  \unction mutePlayback(muted) {
  if (audioEl) audioEl.muted = muted;
  if (window.player && typeof window.player.mute === 'function') {
    if (muted) window.player.mute(); else window.player.unMute();
  }
  if (window.Capacitor && window.Capacitor.Plugins.YouTubeCapacitorPlugin && window.Capacitor.Plugins.YouTubeCapacitorPlugin.setVolume) {
    window.Capacitor.Plugins.YouTubeCapacitorPlugin.setVolume({ volume: muted ? 0.0 : 1.0 }).catch(()=>{});
  }
}
function updateLyricsSync(currentTime){
  if (!currentSyncedLyrics || !currentSyncedLyrics.length) return;
  let idx = -1;
  for (let i = 0; i < currentSyncedLyrics.length; i++) {
    if (currentSyncedLyrics[i].time <= currentTime + lyricOffset + 0.15) idx = i; else break;
  }
  if (idx === lastActiveLyricIndex) return;
  lastActiveLyricIndex = idx;
  
  const setting = getProfanitySetting();
  if (setting === 'mute' || setting === 'both') {
    if (idx >= 0 && currentSyncedLyrics[idx] && hasProfanity(currentSyncedLyrics[idx].text)) mutePlayback(true);
    else mutePlayback(false);
  } else {
    mutePlayback(false);
  }

  const txt = document.getElementById('npLyricsText');
  if (!txt) return;
  const lines = txt.children;
  for (let i = 0; i < lines.length; i++) {
    lines[i].classList.toggle('active', i === idx);
    lines[i].classList.toggle('done', i < idx);
  }
  if (idx >= 0 && lines[idx]) lines[idx].scrollIntoView({ behavior: 'smooth', block: 'center' });
}\\n\
);

content = content.replace(
  /document\\.getElementById\\('npClose'\\)\\.addEventListener\\('click',closeNP\\);/,
  \document.getElementById('npClose').addEventListener('click',closeNP);
  const npHideLyricsBtn = document.getElementById('npHideLyrics');
  if (npHideLyricsBtn) {
    npHideLyricsBtn.addEventListener('click', () => {
      const lyricsEl = document.getElementById('npLyrics');
      const nowPlayingEl = document.getElementById('nowPlaying');
      if (lyricsEl.classList.contains('hidden')) {
        lyricsEl.classList.remove('hidden');
        nowPlayingEl.classList.remove('no-lyrics');
      } else {
        lyricsEl.classList.add('hidden');
        nowPlayingEl.classList.add('no-lyrics');
      }
    });
  }\
);

fs.writeFileSync('c:/Users/xalan/Downloads/MoonDlc_Extracted/music-player-ios-ready/public/player.html', content);
console.log('Success');
