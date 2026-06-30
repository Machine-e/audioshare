use cpal::traits::{DeviceTrait, HostTrait};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct AudioConfig {
    pub sample_rate: u32,
    pub channels: u16,
    pub frame_ms: u16,
    pub bitrate_kbps: u16,
    pub buffer_ms: u16,
}

impl Default for AudioConfig {
    fn default() -> Self {
        Self {
            sample_rate: 48_000,
            channels: 2,
            frame_ms: 20,
            bitrate_kbps: 96,
            buffer_ms: 80,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct OutputDeviceInfo {
    pub id: String,
    pub name: String,
    pub is_default: bool,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct StreamStats {
    pub latency_ms: u32,
    pub packet_loss_percent: f32,
    pub bitrate_kbps: u16,
    pub jitter_ms: u32,
}

pub fn list_output_devices() -> Vec<OutputDeviceInfo> {
    let host = cpal::default_host();
    let default_name = host
        .default_output_device()
        .and_then(|device| device.name().ok());

    let Ok(devices) = host.output_devices() else {
        return Vec::new();
    };

    devices
        .enumerate()
        .filter_map(|(index, device)| {
            let name = device.name().ok()?;
            let is_default = default_name.as_ref() == Some(&name);
            Some(OutputDeviceInfo {
                id: index.to_string(),
                name,
                is_default,
            })
        })
        .collect()
}
