# Getting started (no computer skills needed)

This makes your PC remember the last few minutes of whatever game you are
playing. When something cool happens, you press one key and that moment is
saved as a video file in a folder named after the game. You never have to
remember to hit "record".

Everything below is click-by-click. It takes about 10 minutes once.

---

## Part 1: Install OBS (the program that does the recording)

1. Open your web browser and go to **https://obsproject.com**
2. Click the big **Windows** button. A file downloads.
3. Open the downloaded file (it is called something like
   `OBS-Studio-33.0.1-Windows-x64-Installer.exe`). Click **Next**, **Next**,
   **Install**, **Finish**. Leave every option the way it is.
4. OBS opens. A window called **Auto-Configuration Wizard** appears.
   - Pick **"Optimize just for recording, I will not be streaming"**.
   - Click **Next**, then **Next** again, wait for it to finish, then
     **Apply Settings**.
5. **Close OBS** (click the X in the top-right corner). If it asks "are you
   sure", click **Yes**.

OBS is now installed. You will not need to open it by hand again.

---

## Part 2: Get the replay-buffer files

1. Go to **https://github.com/blarer/obs-replay-buffer**
2. Click the green **Code** button, then **Download ZIP**.
3. Open your **Downloads** folder. You will see
   `obs-replay-buffer-main.zip`.
4. **Right-click** it and choose **Extract All...**, then **Extract**.
   A folder called `obs-replay-buffer-main` appears.
5. **Move that folder somewhere permanent.** A good place is your
   **Documents** folder. Drag it there.

   Why: the program runs from inside this folder forever. If you delete or
   move the folder later, it stops working (you would just run setup again,
   see Part 6).

---

## Part 3: Run the setup

1. Open the `obs-replay-buffer-main` folder you just moved.
2. Find the file called **`setup`** (its full name is `setup.cmd`; it has a
   little gear-and-window icon). **Double-click it.**
3. A black window opens and text scrolls by for about 20 seconds.
   - If Windows shows a blue box saying **"Windows protected your PC"**,
     click **More info**, then **Run anyway**. (That box appears for any
     program that isn't from the Microsoft Store.)
   - If OBS was open, setup closes it and opens it again by itself. That is
     normal.
4. When it finishes, every line should start with **`[ok]`** and the last
   lines say:

   ```
   Done. Press your save hotkey (default Alt+Z) in a game; the clip lands in Videos\<game>\.
   ```

5. Press any key to close the black window.

OBS is now running hidden in the corner of your taskbar (the little arrow
next to the clock). Leave it there.

---

## Part 4: Use it

1. Play a game.
2. When something happens that you want to keep, press **Alt + Z**
   (hold the **Alt** key, tap **Z**).
   - You can change this key later in Part 5.
3. That's it. The last **2 minutes** before you pressed the key are saved.

**Where did it go?**
Open **File Explorer** (the yellow folder icon), click **Videos** on the
left. You will see a folder named after the game, for example
`FortniteClient-Win64-Shipping`. Your clip is inside.

Each clip is named with the date and time, like `Replay 2026-11-19 20-14-33.mp4`.
Double-click it to watch.

---

## Part 5: Things you might want to change

Open OBS from the Start menu to change these. Close it afterwards (the
system reopens it hidden within a minute).

**Save more or less than 2 minutes**
Settings (bottom-right) > **Output** > scroll to **Replay Buffer** >
**Maximum Replay Time** > type a number of seconds (300 = 5 minutes).
Click **OK**.

**Use a different key than Alt+Z**
Settings > **Hotkeys** > find **"Save Replay"** > click the box next to it >
press the key you want > click **OK**.

**Better or worse video quality**
Settings > **Output** > **Recording Quality**. Higher quality = bigger files.

---

## Part 6: If something seems wrong

**Check if everything is working**
In the `obs-replay-buffer-main` folder, double-click **`setup`** again. It
is safe to run as many times as you like. At the end it prints a report;
every line should say `[ok]`. Any line that says `[warn]` tells you what is
wrong in plain words.

**"My clips go to the Videos folder but not into a game folder"**
Run `setup` again, then restart your computer.

**"A message popped up saying OBS closed"**
That is the safety net. If you closed OBS by accident, click **Relaunch
now**. If you closed it on purpose (for example to play a game that doesn't
like OBS), click **Stay off 5 min**. If you ignore it, OBS comes back on its
own after 5 minutes.

**"I want to turn the whole thing off"**
In the `obs-replay-buffer-main` folder, double-click **`uninstall`**. It
removes the automatic start and the hidden watcher. Your clips and OBS stay.
To turn it back on, double-click `setup` again.

**"I moved or renamed the folder"**
Double-click `setup` in the folder's new location. It fixes everything up.

---

## What this does NOT do

- It does not stream anything to the internet. Nothing leaves your PC.
- It does not record all the time to disk. It keeps the last few minutes in
  memory and only writes a file when you press the key.
- It does not need an account or sign-in of any kind.
