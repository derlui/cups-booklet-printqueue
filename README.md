# cups-booklet-printqueue
A Linux installer script that creates virtual CUPS printer queues for automatic booklet imposition and duplex printing.


## Overview

Booklet PrintQueue simplifies booklet printing by creating virtual CUPS printers that automatically:
1. **Reorder pages** for saddle-stitch (fold-in-the-middle) binding
2. **Impose pages** into a 2-up landscape layout (two input pages side-by-side on one output page)
3. **Force duplex printing** with short-edge binding orientation
4. **Pad pages** automatically to multiples of 4 as required for booklet layout

Simply print to the `Booklet-<PrinterName>` queue instead of your regular printer, and the output is ready to fold and bind.

## How It Works

### User-Facing

1. Select a virtual `Booklet-PrinterName` queue from your print dialog
2. Use any native printer options (color mode, paper tray, quality, etc.) — these are inherited from the real printer
3. Click print
4. Your document is automatically converted (if needed), reordered, and imposed for booklet binding, then sent to the physical printer with duplex short-edge selected

### Architecture

The installer creates a two-stage CUPS pipeline:

- **CUPS Filter** (`cups-booklet-filter`): A Python script that performs booklet imposition using pypdf
  - Pads pages to a multiple of 4
  - Reorders pages for saddle-stitch binding
  - Outputs a 2-up landscape PDF

- **CUPS Backend** (`booklet`): A custom backend that forwards the imposed PDF to the real printer
  - Forces `sides=two-sided-short-edge` for proper duplex binding orientation
  - Encapsulates the real printer's URI for transparent operation

- **Virtual Queues**: One per selected printer, using the real printer's PPD (when available) to preserve native driver options

## Requirements

- **Linux**: Debian/Ubuntu (apt-based distributions)
- **CUPS**: Print server (typically pre-installed on desktop environments)
- **Python 3**: Scripting runtime (typically pre-installed)
- **pypdf**: Python library for PDF manipulation (installed automatically via apt or pip3)

## Installation

### Download and run

download `install-booklet-printqueue.sh` from this repository

```bash
chmod +x install-booklet-printqueue.sh
sudo ./install-booklet-printqueue.sh
```

### What the Installer Does

1. Checks for required dependencies (CUPS, Python 3, pypdf)
2. Auto-detects existing CUPS printers and presents a numbered menu for selection
3. Alternatively, accepts manual printer URIs (e.g., `ipp://hostname/printers/PrinterName`)
4. Creates virtual `Booklet-<PrinterName>` queues for each selected printer
5. Stores configuration in `/etc/booklet-printers.conf` for future reference and editing

## Usage

### Printing a Booklet

1. Open any print dialog (browser, PDF viewer, office suite, etc.)
2. Select a `Booklet-<PrinterName>` queue
3. Configure any printer-specific options (color, tray, quality)
4. Click print

The document is automatically reordered and imposed; no additional steps required.

### Testing the Filter Standalone

To verify the booklet imposition without printing:

```bash
/usr/lib/cups/filter/cups-booklet-filter input.pdf > booklet.pdf
```

This outputs the imposed PDF to `booklet.pdf`.

## Managing Printers

### Add or Remove Printers

Edit the configuration file:

```bash
sudo nano /etc/booklet-printers.conf
```

Add or remove printer URIs (one per line), then re-run the installer:

```bash
sudo ./install-booklet-printqueue.sh
```

The installer will update the virtual queues to match the new configuration.

### Manual Printer URI Format

If auto-detection doesn't find your printer, you can add it manually using its URI:

- USB printer: `usb://Manufacturer/Model`
- Network printer (IPP): `ipp://hostname/printers/QueueName`
- Network printer (LPD): `lpd://hostname/QueueName`

## Uninstallation

To remove all virtual booklet queues and restore the original CUPS configuration:

```bash
sudo ./install-booklet-printqueue.sh --remove
```

This removes:
- Virtual printer queues
- CUPS filter and backend files
- Configuration file (`/etc/booklet-printers.conf`)

## Technical Notes

### Filter-Based Architecture

- The booklet filter is installed **per-queue** via the `*cupsFilter` PPD directive; no global CUPS configuration is modified
- Each virtual queue inherits the real printer's PPD (or falls back to a generic PPD), preserving native driver options
- This design allows multiple filter types to coexist without conflicts

### Backend Design

- The custom `booklet` backend receives the imposed PDF from the filter and forwards it to the real printer
- The backend forces `sides=two-sided-short-edge` unconditionally, ensuring correct binding orientation regardless of print dialog settings
- The real printer's URI is embedded in each virtual queue's configuration

### Dependencies and Rationale

- **pypdf** (~1 MB) is used for imposition
- Only Python 3 (typically pre-installed on Linux systems) is required as a runtime dependency

### CUPS PPD Deprecation Notice

**Important:** CUPS is gradually deprecating PPD (PostScript Printer Description) files in favor of IPP (Internet Printing Protocol). This tool relies on PPD-based configuration. While PPD support remains stable in CUPS 2.x, this may not be the case in future major versions.

## Troubleshooting

- **Printer not found**: Run the installer again to re-scan for available CUPS printers
- **Duplex not working**: Check that your physical printer supports duplex; verify with `lpadmin -p <printername> -l` to list capabilities
- **Filter errors**: Check CUPS error log at `/var/log/cups/error_log`
- **Permission denied**: Ensure you run the installer with `sudo`

## License

MIT

## Contributing

Please fork this project, as I probably won't have time to look into issues.

---

