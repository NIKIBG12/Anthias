Stage 1 — C++ webview: live setVolume slot (Qt6 only)

In src/anthias_webview:
1. In mainwindow.h, inside the existing #if QT_VERSION >= 6 block (near playVideo/stopVideo), 
   add a new public slot: void setVolume(int percent); — no default argument.
2. In mainwindow.cpp, implement MainWindow::setVolume(int percent) mirroring how playVideo 
   forwards to View — call view->setVolume(percent) (or the equivalent path to VideoView).
3. In view.h/view.cpp, add a matching setVolume(int percent) that forwards to VideoView::setVolume.
4. In videoview.h, add: int m_volume = 100; and a public slot void setVolume(int percent);
5. In videoview.cpp, implement:
   void VideoView::setVolume(int percent) {
       percent = qBound(0, percent, 100);
       m_volume = percent;
       if (audioOutput) {
           audioOutput->setVolume(m_volume / 100.0f);
       }
   }
6. In VideoView::play() (videoview.cpp:313 area), after the audio-device handling, also read 
   options.value("volume") if present and call setVolume() with it, so a fresh play() call 
   applies the saved setting even if no live command was received yet (e.g. after a viewer restart).
Build and confirm it compiles cleanly against Qt6. This only affects x86/Pi4/Pi5/arm64/pi3-64 
non-gst mode — Pi1-3 has no video slots at all, unaffected.

Stage 2 — Python viewer: Redis command + live push

In src/anthias_viewer:
1. In __init__.py, find the commands dict (near :823) and add:
   'volume': self._handle_volume
2. Implement _handle_volume(self, parameter):
   - parse int(parameter), clamp 0-100
   - if the active player exposes the webview D-Bus proxy (Qt6 path), call bus.setVolume(value) 
     the same guarded way playVideo/stopVideo are called elsewhere (reuse the existing D-Bus 
     wrapper that restarts the webview if it died mid-call, mentioned around media_player.py:38-71)
   - for GstFbdevMediaPlayer / pi3-64 gst-mode, this is a no-op — the value already landed in 
     settings via settings_save/PATCH, and get_alsa_audio_device()'s sibling code path 
     (_build_video_options) will pick up the new volume on the next asset via settings.load()
3. In media_player.py, in _build_video_options() (~line 562-610), add 'volume': settings['volume'] 
   to the options dict sent to playVideo, so a fresh play() always carries the current setting.
4. In gst_fbdev_player.py, add --volume argument (parse_args ~:210) and in build_and_start() 
   (~:371) call playbin.set_property('volume', args.volume / 100.0) — this covers Pi 1-3, 
   applying on next-clip since that helper has no live channel.
5. In media_player.py:825, add '--volume', str(settings['volume']) to the GstFbdevMediaPlayer 
   command line args alongside --audio-device.

Stage 3 — Django settings: the six places

In src/anthias_server:
1. settings.py:70 — add 'volume': 100 to the defaults dict.
2. app/page_context.py — in device_settings(), add volume alongside audio_output (~:582).
3. app/templates/settings.html — replace the audio_output <select> pattern with a range 
   input near it:
   <input type="range" class="app-range" id="volume" name="volume" min="0" max="100" 
       value="{{ volume }}">
   (check if there's an existing _settings_range.html partial pattern like _settings_toggle.html; 
   if not, plain input is fine — match existing CSS classes for consistency)
4. app/views.py, settings_save (~:1897) — add:
   settings['volume'] = int(request.POST.get('volume', 100))
   ...after settings.save(), in addition to send_to_viewer('reload'), also call 
   send_to_viewer(f'volume&{settings["volume"]}') so the change applies immediately 
   instead of waiting for reload's next-asset pickup.
5. api/serializers/v2.py — add volume = IntegerField(required=False) to both 
   DeviceSettingsSerializerV2 (:420) and UpdateDeviceSettingsSerializerV2 (:450), with a 
   validate_volume method enforcing 0-100 (match the validate_timezone style at :526).
6. api/views/v2.py, DeviceSettingsViewV2 — add 'volume': settings['volume'] to get() (~:571); 
   in patch() (~:657), add the if 'volume' in data: settings['volume'] = data['volume'] branch, 
   and after settings.save(), send both 'reload' and f'volume&{settings["volume"]}' as in step 4.
7. ViewerSettingsSerializerV2 (:551) — add volume too, so the viewer's own settings.load() 
   sees the current value on startup/reload.

Stage 4 — sanity checks

1. Run tests/test_media_player.py and add a case for get_alsa_audio_device()'s neighbor — 
   check if there's a natural place to add a volume-clamping test near it.
2. docker compose -f docker-compose.dev.yml up, load a video asset, hit the settings page, 
   drag the volume slider, confirm sound level changes without a visible reload/flicker 
   on the x86 dev container.
3. Confirm the v2 PATCH endpoint (/api/v2/device_settings) also changes volume live via curl, 
   independent of the HTML form.