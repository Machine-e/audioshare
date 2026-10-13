# Android UI and update downloads (0.2.6)

- Update downloads send real byte counts through
  `com.machinee.audioshare/update_progress`, at most every 100ms plus initial/final
  events. Each attempt has a request ID so old events cannot overwrite a retry.
  Unknown content length shows an indeterminate bar and downloaded MB. The final
  phase means opening the system installer, not installation success.
- Returning from the background keeps the in-flight download locked. Completion
  or failure releases it. Native code rejects concurrent requests, verifies the
  declared byte length, and only renames a complete temporary file to the APK.
  Destroying the Activity cancels its connection; this is not a download service
  and does not promise survival across process death or resumable downloads.
- Computer messages, errors and action feedback have separate padded surfaces.
  Receiver explanations, troubleshooting, empty-device actions and device labels
  use explicit spacing. Update actions are below their text, so large fonts do
  not squeeze the download description into a narrow column.
- MiSans Regular, Medium and Semibold are bundled unmodified from Xiaomi's
  official package. The original license and source are in
  `assets/fonts/misans/`; the UI does not display a font credit label.
- The light phone-broadcast icon pairs a tilted blue phone with coral sound arcs. Generate
  it with `python scripts/generate_app_icon.py` (Pillow required). The script updates the
  editable SVG, preview PNG, Android adaptive/monochrome and legacy icons, and
  the Windows ICO. Launcher shortcuts and the quick-settings tile use the new
  artwork too.

Validation: Flutter tests cover actual progress events, stale requests, unknown
length, background/resume, failed retry, completion and a 320px/2x text layout.
Kotlin tests cover copying/throttling, unknown length, incomplete content and
cancellation. Render previews use bundled MiSans through Flutter tests; no
desktop UI automation is needed.
