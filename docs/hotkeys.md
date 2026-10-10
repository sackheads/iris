# Global Hotkeys

Iris runs in the background of macOS as a persistent native application, allowing you to invoke it instantly over any other application. 

By default, the shortcut to toggle the main Iris Chat window is **`Cmd + Shift + Space`**.

## How It Works
*   **Active Overlays:** When you press the hotkey, Iris checks whether the chat window is the one in front: Iris is the active app and the chat window has focus.
*   **Show:** If the chat window is hidden, minimized, behind other applications, or behind another Iris window (Diagnostics, say), the hotkey brings it to the front. If you closed it, the hotkey opens it again.
*   **Hide:** If the chat window is already in front, the hotkey orders it out (hides it), returning focus to whatever you were previously working on.

## Customization
You can easily customize the hotkey at any time:
1.  Open the **Settings Window** (`Cmd + ,` or via the Menu Bar).
2.  Locate the **Global Shortcuts** section at the top of the pane.
3.  Click the recorder next to **Toggle Iris**.
4.  Press your desired key combination.

The new shortcut will be applied instantly and bound via macOS's native `KeyboardShortcuts` implementation, requiring no system restarts.
