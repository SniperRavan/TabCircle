TabCircle — Setup Guide
================================================================

1. Install
   Drag TabCircle.app into the Applications folder on the left.

2. macOS will block the first launch
   If you see "cannot be opened because the developer cannot be verified"
   or "is damaged", that is because this app is not signed with a paid
   Apple Developer certificate — nothing is actually wrong with it.

   Either of these works:

   a) In Applications, RIGHT-CLICK TabCircle → Open → Open
      (once only; double-click works from then on)

   b) In Terminal:
        xattr -dr com.apple.quarantine /Applications/TabCircle.app

3. Grant Accessibility permission
   TabCircle intercepts ⌃⇥ before Chrome receives it, which macOS only
   allows for apps with Accessibility access. The first launch shows a
   prompt, or go to:

     System Settings → Privacy & Security → Accessibility → enable TabCircle

   Relaunch TabCircle afterwards — macOS only reads this permission when a
   process starts.

4. Install the Chrome extension (required)
   TabCircle is two halves and needs both. Load the extension manually:

     1. Open chrome://extensions
     2. Turn on Developer mode (top right)
     3. Click "Load unpacked"
     4. Select the extension folder from the source repository
        (get it at https://github.com/sniperravan/TabCircle)

   The menu bar icon brightens and reads "Connected" once they connect.

5. Why permission resets after each update
   Without a developer certificate the app can only be ad-hoc signed.
   macOS identifies such apps by their code hash, which changes with every
   build — so after an update the system treats it as a different app and
   ACCESSIBILITY PERMISSION MUST BE GRANTED AGAIN.
   TabCircle detects this at launch and walks you through it.

   To avoid this entirely, build from source and sign with your own
   certificate.

================================================================
https://github.com/sniperravan/TabCircle
