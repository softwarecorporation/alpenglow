use crepuscularity_tui::{ratatui, Template};
use ratatui::{
    backend::{Backend, CrosstermBackend},
    Terminal,
};
use std::io::{self, IsTerminal, Write};
use std::path::Path;

const UI: &str = include_str!("../ui/tui.crepus");

pub fn confirm_installation(
    source: &Path,
    disk: &crate::DiskIdentity,
) -> Result<Option<String>, String> {
    if !io::stdin().is_terminal() {
        return Err("--tui requires an interactive terminal; no data written".into());
    }
    draw_installer_tui(source, Some(&disk.path))?;
    println!(
        "\nDisk: {} — {} bytes — removable: {}",
        disk.model, disk.size_bytes, disk.removable
    );
    print!(
        "Type {} to erase {} (Enter or Ctrl+C cancels): ",
        disk.path.file_name().unwrap_or_default().to_string_lossy(),
        disk.path.display()
    );
    io::stdout().flush().map_err(|error| error.to_string())?;
    let mut confirmation = String::new();
    io::stdin()
        .read_line(&mut confirmation)
        .map_err(|error| error.to_string())?;
    let confirmation = confirmation.trim();
    Ok(if confirmation.is_empty() {
        None
    } else {
        Some(confirmation.to_string())
    })
}

pub fn draw_installer_tui(source: &Path, target: Option<&Path>) -> Result<(), String> {
    let backend = CrosstermBackend::new(io::stdout());
    let mut terminal = Terminal::new(backend).map_err(|err| err.to_string())?;
    draw_installer_tui_internal(&mut terminal, source, target)?;
    let height = terminal.size().map_err(|err| err.to_string())?.height;
    terminal
        .set_cursor_position((0, height.saturating_sub(1)))
        .map_err(|err| err.to_string())?;
    terminal.show_cursor().map_err(|err| err.to_string())
}

pub fn draw_installer_tui_internal<B: Backend>(
    terminal: &mut Terminal<B>,
    source: &Path,
    target: Option<&Path>,
) -> Result<(), String> {
    let mut ui = Template::from_source(UI);
    ui.set("source", source.display().to_string());
    ui.set(
        "target",
        target
            .map(|path| path.display().to_string())
            .unwrap_or_else(|| "pass target disk as second argument".to_string()),
    );
    terminal
        .draw(|frame| {
            let _ = ui.draw_full(frame);
        })
        .map_err(|err| err.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::backend::TestBackend;

    #[test]
    fn test_draw_installer_tui_internal() {
        let backend = TestBackend::new(100, 40);
        let mut terminal = Terminal::new(backend).unwrap();

        let source = Path::new("/dev/sda");
        let target = Some(Path::new("/dev/sdb"));

        let result = draw_installer_tui_internal(&mut terminal, source, target);
        assert!(result.is_ok());

        let rendered: String = terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect();
        assert!(rendered.contains("Alpenglow Installer"));
        assert!(rendered.contains("Writes the release image to a target disk"));
        assert!(rendered.contains("Source: /dev/sda"));
        assert!(rendered.contains("Target: /dev/sdb"));
        assert!(rendered
            .contains("Use: alpenglow-install --tui /run/alpenglow/alpenglow.img.zst /dev/sdX"));
        assert!(rendered.contains("Press Ctrl+C to cancel."));
    }

    #[test]
    fn test_draw_installer_tui_internal_no_target() {
        let backend = TestBackend::new(100, 40);
        let mut terminal = Terminal::new(backend).unwrap();

        let source = Path::new("/dev/sda");
        let target = None;

        let result = draw_installer_tui_internal(&mut terminal, source, target);
        assert!(result.is_ok());

        let rendered: String = terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect();
        assert!(rendered.contains("Alpenglow Installer"));
        assert!(rendered.contains("Writes the release image to a target disk"));
        assert!(rendered.contains("Source: /dev/sda"));
        assert!(rendered.contains("Target: pass target disk as second argument"));
        assert!(rendered
            .contains("Use: alpenglow-install --tui /run/alpenglow/alpenglow.img.zst /dev/sdX"));
        assert!(rendered.contains("Press Ctrl+C to cancel."));
    }
}
