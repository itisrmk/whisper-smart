use anyhow::Result;

pub trait ClipboardInserter: Send {
    fn insert_text(&self, text: &str) -> Result<()>;
}

#[derive(Default)]
pub struct MacOsClipboardInserter;

impl ClipboardInserter for MacOsClipboardInserter {
    fn insert_text(&self, text: &str) -> Result<()> {
        // TODO: implement AX insertion + Cmd-V fallback parity with Swift app.
        println!("[clipboard stub] Would inject: {text}");
        Ok(())
    }
}
