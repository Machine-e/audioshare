use crate::audio::{list_output_devices, AudioConfig, CpalOutputSink, PcmOutputSink, StreamStats};
use crate::codec::OpusCodec;
use crate::jitter::{JitterBuffer, JitterPop};
use crate::protocol::AudioPacket;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::slice;
use std::str;

pub struct FfiOpusPlayer {
    config: AudioConfig,
    codec: OpusCodec,
    jitter: JitterBuffer,
    sink: CpalOutputSink,
    stats: StreamStats,
}

#[repr(C)]
pub struct FfiOutputDevice {
    pub id: [u8; 64],
    pub name: [u8; 256],
    pub is_default: u8,
}

#[no_mangle]
pub unsafe extern "C" fn audioshare_list_output_devices(
    devices: *mut FfiOutputDevice,
    capacity: usize,
) -> usize {
    if devices.is_null() || capacity == 0 {
        return 0;
    }

    let result = catch_unwind(AssertUnwindSafe(|| {
        let output_devices = list_output_devices();
        let len = output_devices.len().min(capacity);
        let out = slice::from_raw_parts_mut(devices, len);
        for (slot, device) in out.iter_mut().zip(output_devices) {
            write_fixed_utf8(&mut slot.id, &device.id);
            write_fixed_utf8(&mut slot.name, &device.name);
            slot.is_default = u8::from(device.is_default);
        }
        len
    }));

    result.unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn audioshare_player_create(
    sample_rate: u32,
    channels: u16,
    frame_ms: u16,
    bitrate_kbps: u16,
    buffer_ms: u16,
    output_device: *const u8,
    output_device_len: usize,
) -> *mut FfiOpusPlayer {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let config = AudioConfig {
            sample_rate,
            channels,
            frame_ms,
            bitrate_kbps,
            buffer_ms,
        };
        let output_device = ffi_string(output_device, output_device_len)?;
        let codec = OpusCodec::new(config.clone()).ok()?;
        let jitter = JitterBuffer::new(config.jitter_target_frames());
        let sink = CpalOutputSink::open_selected(output_device.as_deref(), &config).ok()?;
        Some(Box::new(FfiOpusPlayer {
            config,
            codec,
            jitter,
            sink,
            stats: StreamStats::default(),
        }))
    }));

    match result {
        Ok(Some(player)) => Box::into_raw(player),
        _ => ptr::null_mut(),
    }
}

fn ffi_string(value: *const u8, len: usize) -> Option<Option<String>> {
    if value.is_null() || len == 0 {
        return Some(None);
    }
    let bytes = unsafe { slice::from_raw_parts(value, len) };
    str::from_utf8(bytes)
        .ok()
        .map(|value| Some(value.to_owned()))
}

fn write_fixed_utf8(out: &mut [u8], value: &str) {
    out.fill(0);
    if out.is_empty() {
        return;
    }
    let max_len = out.len() - 1;
    let mut end = value.len().min(max_len);
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    out[..end].copy_from_slice(&value.as_bytes()[..end]);
}

#[no_mangle]
pub unsafe extern "C" fn audioshare_player_push_packet(
    player: *mut FfiOpusPlayer,
    sequence: u64,
    timestamp_ms: u64,
    payload: *const u8,
    payload_len: usize,
) -> i32 {
    if player.is_null() || payload.is_null() {
        return -1;
    }

    let result = catch_unwind(AssertUnwindSafe(|| {
        let player = &mut *player;
        let payload = slice::from_raw_parts(payload, payload_len);
        let packet = AudioPacket {
            session_id: 0,
            sequence,
            timestamp_ms,
            payload: payload.to_vec(),
        };
        player.stats.udp_packets_received += 1;
        player.jitter.push(packet);
        drain_ready(player)
    }));

    match result {
        Ok(Ok(played)) => played as i32,
        Ok(Err(code)) => code,
        Err(_) => -4,
    }
}

#[no_mangle]
pub unsafe extern "C" fn audioshare_player_push_opus(
    player: *mut FfiOpusPlayer,
    payload: *const u8,
    payload_len: usize,
) -> i32 {
    audioshare_player_push_packet(player, 0, 0, payload, payload_len)
}

#[no_mangle]
pub unsafe extern "C" fn audioshare_player_destroy(player: *mut FfiOpusPlayer) {
    if player.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        drop(Box::from_raw(player));
    }));
}

fn drain_ready(player: &mut FfiOpusPlayer) -> Result<usize, i32> {
    let mut played = 0;
    loop {
        match player.jitter.pop_next() {
            JitterPop::Packet(packet) => {
                let pcm = player.codec.decode_i16(&packet.payload).map_err(|_| -2)?;
                player.sink.play(&pcm).map_err(|_| -3)?;
                player.stats.played_frames += 1;
                played += 1;
            }
            JitterPop::Missing { .. } => {
                let silence = vec![0_i16; player.config.samples_per_frame()];
                player.sink.play(&silence).map_err(|_| -3)?;
                player.stats.underruns += 1;
                player.stats.played_frames += 1;
                played += 1;
            }
            JitterPop::NotReady => break,
        }
    }
    Ok(played)
}
