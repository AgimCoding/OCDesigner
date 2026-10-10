# OCDesigner

### Visual OpenCore EFI Boot Menu Editor for Windows

**OCDesigner** is a free, Windows-based graphical application designed to customize, configure, and manage the **OpenCore boot picker** used in Hackintosh systems.

Built with **PowerShell 5.1 and Windows Presentation Foundation (WPF)**, OCDesigner provides an intuitive interface for editing OpenCore boot settings, managing OpenCanopy themes, customizing icons and backgrounds, and previewing changes without manually editing XML files.

**Developed by [AgimCoding](https://github.com/AgimCoding)**

---

## Features

### Visual Boot Menu Editor

Customize your OpenCore boot picker through a graphical interface.

- Live graphical preview of the boot menu
- Customize boot picker appearance
- Configure background colors and images
- Adjust screen resolution and UI scaling
- Preview installed themes
- Customize boot entry icons
- Manage graphical boot options

### OpenCanopy Theme Manager

Manage your OpenCanopy themes directly from OCDesigner.

- Browse installed themes
- Import existing themes
- Duplicate themes for customization
- Install themes from an integrated online catalog
- Replace individual theme icons
- Customize boot menu backgrounds
- Manage OpenCanopy resources
- Install or enable the OpenCanopy driver

### Online Theme Library

Explore and install OpenCanopy themes from supported community sources.

The integrated catalog includes themes from:

- [Acidanthera — OcBinaryData](https://github.com/acidanthera/OcBinaryData)
- [Blackosx — OpenCanopyIcons](https://github.com/blackosx/OpenCanopyIcons)

Preview available themes and install them directly into your selected EFI configuration.

An internet connection is required to download online themes.

### OpenCore Configuration Editor

Modify supported OpenCore settings without manually editing `config.plist`.

Available settings include:

| Category | Settings |
|---|---|
| Boot Picker | PickerMode, PickerVariant |
| Appearance | PickerAttributes, ConsoleAttributes |
| Boot Behavior | ShowPicker, Timeout, HideAuxiliary |
| Display | UIScale, Resolution, TextRenderer |
| Additional Options | PickerAudioAssist, AllowSetDefault and more |

OCDesigner only modifies supported settings already present in your configuration, helping preserve compatibility with different OpenCore versions.

### Automatic Backup and Restore

Protect your EFI configuration before making changes.

- Automatic backups before modifications
- Manual full EFI backups
- Restore previous configurations
- Safety backups before restoration
- Up to 60 automatically retained backups

Backups are stored in:

`%LOCALAPPDATA%\OCDesigner\Backups`

### Multilingual Interface

OCDesigner supports three interface languages:

- English
- Français
- Nederlands

---

## Screenshots

*Screenshots of the main interface, theme manager, live preview, and backup manager will be added here.*

---

## System Requirements

| Component | Requirement |
|---|---|
| Operating System | Windows with WPF support |
| PowerShell | Windows PowerShell 5.1 |
| Graphics Interface | Windows Presentation Foundation (WPF) |
| OpenCore | Existing OpenCore EFI configuration |
| Internet | Optional, required for online themes |

OCDesigner runs on Windows and does not require macOS to edit an OpenCore EFI configuration.

---

## Installation

### 1. Download OCDesigner

Download the project from GitHub:

[OCDesigner Repository](https://github.com/AgimCoding/OCDesigner)

Select **Code → Download ZIP**, then extract the archive to a folder of your choice.

### 2. Launch the Application

Open Windows PowerShell and navigate to the extracted folder.

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\OCDesigner.ps1"
```

The graphical interface will launch.

**Note:** The execution-policy override applies to this PowerShell process. Only run scripts downloaded from sources you trust.

### 3. Select Your EFI Folder

Open your OpenCore EFI directory.

Example:

```text
EFI/
└── OC/
    ├── ACPI/
    ├── Drivers/
    ├── Kexts/
    ├── Resources/
    ├── Tools/
    ├── OpenCore.efi
    └── config.plist
```

You can also launch OCDesigner with a predefined EFI path:

```powershell
.\OCDesigner.ps1 -EfiPath "Z:\EFI\OC"
```

---

## How to Use

### Customize Your Boot Menu

1. Launch OCDesigner.
2. Select your OpenCore EFI directory.
3. Review the current boot picker configuration.
4. Select an existing theme or install a new one.
5. Customize the icons, background, and appearance.
6. Preview the changes.
7. Save your configuration.
8. Reboot your Hackintosh to see the result.

### Install an OpenCanopy Theme

1. Open the theme manager.
2. Browse the available themes.
3. Select a theme from the online catalog.
4. Preview its appearance.
5. Install the selected theme.
6. Apply the appropriate OpenCore boot picker settings.
7. Save your configuration.

### Restore a Previous Configuration

If a modification produces unexpected results:

1. Open the backup manager.
2. Select a previous backup.
3. Restore the selected configuration.
4. Verify the restored EFI before rebooting.

---

## Safety and Compatibility

OCDesigner is designed to preserve the integrity of your existing OpenCore configuration.

The application includes several safeguards:

- Automatic backups before writing changes
- Preservation of XML formatting and line endings
- Modifications restricted to existing supported configuration keys
- Backup restoration functionality
- Configuration write verification

**Important:** Editing an EFI partition can prevent a computer from booting if the resulting configuration is incompatible.

Always keep a separate, verified backup of your working EFI and a recovery USB drive before making changes.

OCDesigner does not guarantee that every third-party theme or configuration will work with every OpenCore version.

---

## Project Structure

The main application is implemented in a PowerShell script:

```text
OCDesigner/
├── OCDesigner.ps1
└── README.md
```

Additional launchers, assets, screenshots, and project resources may be included in future releases.

---

## Roadmap

Possible future improvements include:

- Additional OpenCanopy themes
- More boot picker customization options
- Improved visual previews
- Extended configuration validation
- Additional language translations
- Standalone Windows application packaging
- Expanded theme management tools

Suggestions and contributions are welcome.

---

## Contributing

Contributions, bug reports, and feature suggestions are welcome.

If you discover a problem or would like to request a feature, please open an issue in the GitHub repository.

For code contributions, fork the repository and submit a pull request describing your changes.

---

## Credits

OCDesigner is an independent project built around the OpenCore ecosystem.

Special thanks to the developers and contributors of:

- [OpenCorePkg — Acidanthera](https://github.com/acidanthera/OpenCorePkg)
- [OcBinaryData — Acidanthera](https://github.com/acidanthera/OcBinaryData)
- [OpenCanopyIcons — Blackosx](https://github.com/blackosx/OpenCanopyIcons)

All third-party themes, icons, and resources remain the property of their respective authors and are subject to their original licenses.

OCDesigner is not officially affiliated with or endorsed by the OpenCore development team or Apple Inc.

---

## Author

**Anthony Gillet — AgimCoding**

GitHub: [@AgimCoding](https://github.com/AgimCoding)

Made for the Hackintosh and OpenCore community.

---

**OCDesigner — Customize your OpenCore boot experience.**
