# Quran Heart Tracker 📖🫀

A high-performance, desktop-optimized Flutter application designed to visually track Quran memorization (Hifz) progress. 

## Why This Exists
This started strictly as a personal project. I needed a fast, visual, and distraction-free way to track my own Quran progress without relying on heavy commercial apps or subscription services. I engineered it to be efficient and work perfectly for my own daily routine. 

I am open-sourcing it and sharing the executable here purely with the intention that it might help someone else in their memorization journey. It is a simple tool to help you stay consistent, nothing more, nothing less. May Allah accept our efforts.

## Features & Engineering
Under the hood, this isn't just a basic image clicker. It is optimized for desktop performance:
* **Isolate-driven BFS (Breadth-First Search):** The flood-fill algorithm processes thousands of pixels in a background thread, meaning the UI never freezes or lags when coloring large sections.
* **Debounced Hover Tracking:** Real-time visual feedback (Gold Hover) that calculates regions instantly without overloading the main thread.
* **Desktop Controls:** Custom-built mouse-wheel interception and unbounded trackpad panning, making it feel like a professional desktop map rather than a ported mobile app.
* **Automated Connected-Components Counting:** Progress is calculated mathematically by counting distinct regions, ensuring accurate tracking.

## 📥 How to Download and Use (For Regular Users)
You do not need to know how to code to use this app.
1. Go to the **[Releases](../../releases)** section on the right side of this page.
2. Download the `Quran_Heart_Tracker.zip` file from the latest release.
3. **Right-click** the `.zip` file and select **Extract All...** (Do not just double-click to peek inside).
4. Open the extracted folder and double-click `1_Create_Desktop_Shortcut.bat`. This will automatically place the tracker on your desktop for easy daily access.

## 💻 For Developers
If you want to run the source code, fork the project, or build it yourself:

```bash
# Clone the repository
git clone [https://github.com/ZyadAhmed-DataEngineer/Quran_Heart_Tracker.git](https://github.com/ZyadAhmed-DataEngineer/Quran_Heart_Tracker.git)

# Navigate into the directory
cd Quran_Heart_Tracker

# Get dependencies
flutter pub get

# Run on Windows
flutter run -d windows
