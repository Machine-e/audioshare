use anyhow::{Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, Stream};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct AudioConfig {
    pub sample_rate: u32,
    pub channels: u16,
    pub frame_ms: u16,
    pub bitrate_kbps: u16,
    pub buffer_ms: u16,
}

impl AudioConfig {
    pub fn samples_per_channel_per_frame(&self) -> usize {
        self.sample_rate as usize * self.frame_ms as usize / 1000
    }

    pub fn samples_per_frame(&self) -> usize {
        self.samples_per_channel_per_frame() * self.channels as usize
    }

    pub fn jitter_target_frames(&self) -> usize {
        (self.buffer_ms / self.frame_ms).max(1) as usize
    }
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
    pub pcm_frames_captured: u64,
    pub opus_frames_encoded: u64,
    pub udp_packets_sent: u64,
    pub udp_packets_received: u64,
    pub played_frames: u64,
    pub send_errors: u64,
    pub read_errors: u64,
    pub zero_frames: u64,
    pub underruns: u64,
}

pub trait PcmOutputSink {
    fn play(&mut self, pcm: &[i16]) -> anyhow::Result<()>;
}

pub struct CpalOutputSink {
    queue: Arc<Mutex<VecDeque<i16>>>,
    _stream: Stream,
    max_buffered_samples: usize,
}

impl CpalOutputSink {
    pub fn open_default(config: &AudioConfig) -> Result<Self> {
        let host = cpal::default_host();
        let device = host
            .default_output_device()
            .context("no default output device available")?;
        Self::open(device, config)
    }

    pub fn open_selected(selection: Option<&str>, config: &AudioConfig) -> Result<Self> {
        let Some(selection) = selection.map(str::trim).filter(|value| !value.is_empty()) else {
            return Self::open_default(config);
        };

        if matches!(selection, "default" | "默认输出设备") {
            return Self::open_default(config);
        }

        let host = cpal::default_host();
        let devices = host.output_devices().context("query output devices")?;
        for (index, device) in devices.enumerate() {
            let name = device.name().unwrap_or_default();
            if selection == index.to_string() || selection == name {
                return Self::open(device, config);
            }
        }

        anyhow::bail!("selected output device not found: {selection}")
    }

    pub fn open(device: cpal::Device, config: &AudioConfig) -> Result<Self> {
        let supported = device
            .default_output_config()
            .context("query default output config")?;
        let mut stream_config = supported.config();
        stream_config.channels = config.channels;
        stream_config.sample_rate.0 = config.sample_rate;

        let queue = Arc::new(Mutex::new(VecDeque::<i16>::new()));
        let callback_queue = Arc::clone(&queue);
        let err_fn = |error| eprintln!("AudioShare output stream error: {error}");
        let stream = match supported.sample_format() {
            SampleFormat::I16 => device.build_output_stream(
                &stream_config,
                move |output: &mut [i16], _| fill_output_i16(output, &callback_queue),
                err_fn,
                None,
            ),
            SampleFormat::F32 => device.build_output_stream(
                &stream_config,
                move |output: &mut [f32], _| fill_output_f32(output, &callback_queue),
                err_fn,
                None,
            ),
            SampleFormat::U16 => device.build_output_stream(
                &stream_config,
                move |output: &mut [u16], _| fill_output_u16(output, &callback_queue),
                err_fn,
                None,
            ),
            other => anyhow::bail!("unsupported output sample format: {other:?}"),
        }
        .context("build output stream")?;
        stream.play().context("start output stream")?;

        Ok(Self {
            queue,
            _stream: stream,
            max_buffered_samples: config.samples_per_frame() * config.jitter_target_frames() * 4,
        })
    }
}

impl PcmOutputSink for CpalOutputSink {
    fn play(&mut self, pcm: &[i16]) -> Result<()> {
        let mut queue = self.queue.lock().expect("output queue poisoned");
        queue.extend(pcm);
        while queue.len() > self.max_buffered_samples {
            queue.pop_front();
        }
        Ok(())
    }
}

fn fill_output_i16(output: &mut [i16], queue: &Arc<Mutex<VecDeque<i16>>>) {
    let mut queue = queue.lock().expect("output queue poisoned");
    for sample in output {
        *sample = queue.pop_front().unwrap_or(0);
    }
}

fn fill_output_f32(output: &mut [f32], queue: &Arc<Mutex<VecDeque<i16>>>) {
    let mut queue = queue.lock().expect("output queue poisoned");
    for sample in output {
        *sample = queue
            .pop_front()
            .map_or(0.0, |value| value as f32 / i16::MAX as f32);
    }
}

fn fill_output_u16(output: &mut [u16], queue: &Arc<Mutex<VecDeque<i16>>>) {
    let mut queue = queue.lock().expect("output queue poisoned");
    for sample in output {
        *sample = queue
            .pop_front()
            .map_or(u16::MAX / 2, |value| (value as i32 + 32_768) as u16);
    }
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
