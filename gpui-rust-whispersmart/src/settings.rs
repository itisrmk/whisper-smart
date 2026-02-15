use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppSettings {
    pub global_hotkey: String,
    pub provider: String,
    pub auto_insert: bool,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            global_hotkey: "Option+Space".to_string(),
            provider: "placeholder".to_string(),
            auto_insert: true,
        }
    }
}
