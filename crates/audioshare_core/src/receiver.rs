use crate::audio::{AudioConfig, CpalOutputSink, PcmOutputSink, StreamStats};
use crate::codec::OpusCodec;
use crate::jitter::{JitterBuffer, JitterPop};
use crate::protocol::AudioPacket;
use crate::transport::UdpAudioReceiver;
use anyhow::{Context, Result};
use std::net::SocketAddr;

pub struct WindowsReceiverRuntime<S> {
    receiver: UdpAudioReceiver,
    jitter: JitterBuffer,
    codec: OpusCodec,
    sink: S,
    config: AudioConfig,
    stats: StreamStats,
}

impl<S: PcmOutputSink> WindowsReceiverRuntime<S> {
    pub async fn bind(
        local: SocketAddr,
        key: Vec<u8>,
        config: AudioConfig,
        sink: S,
    ) -> Result<Self> {
        let receiver = UdpAudioReceiver::bind(local, key).await?;
        Ok(Self::new(receiver, config, sink)?)
    }

    pub fn new(receiver: UdpAudioReceiver, config: AudioConfig, sink: S) -> Result<Self> {
        let jitter = JitterBuffer::new(config.jitter_target_frames());
        let codec = OpusCodec::new(config.clone())?;
        Ok(Self {
            receiver,
            jitter,
            codec,
            sink,
            config,
            stats: StreamStats::default(),
        })
    }

    pub fn stats(&self) -> &StreamStats {
        &self.stats
    }

    pub async fn receive_once(&mut self) -> Result<usize> {
        let packet = self.receiver.recv().await?;
        self.push_packet(packet)
    }

    pub fn push_packet(&mut self, packet: AudioPacket) -> Result<usize> {
        self.stats.udp_packets_received += 1;
        self.jitter.push(packet);
        self.drain_ready()
    }

    fn drain_ready(&mut self) -> Result<usize> {
        let mut played = 0;
        loop {
            match self.jitter.pop_next() {
                JitterPop::Packet(packet) => {
                    let pcm = self
                        .codec
                        .decode_i16(&packet.payload)
                        .context("decode received opus payload")?;
                    self.sink.play(&pcm)?;
                    self.stats.played_frames += 1;
                    played += 1;
                }
                JitterPop::Missing { .. } => {
                    let silence = vec![0_i16; self.config.samples_per_frame()];
                    self.sink.play(&silence)?;
                    self.stats.underruns += 1;
                    self.stats.played_frames += 1;
                    played += 1;
                }
                JitterPop::NotReady => break,
            }
        }
        Ok(played)
    }
}

impl WindowsReceiverRuntime<CpalOutputSink> {
    pub async fn bind_default_output(
        local: SocketAddr,
        key: Vec<u8>,
        config: AudioConfig,
    ) -> Result<Self> {
        let sink = CpalOutputSink::open_default(&config)?;
        Self::bind(local, key, config, sink).await
    }

    pub async fn bind_selected_output(
        local: SocketAddr,
        key: Vec<u8>,
        config: AudioConfig,
        output_device: Option<&str>,
    ) -> Result<Self> {
        let sink = CpalOutputSink::open_selected(output_device, &config)?;
        Self::bind(local, key, config, sink).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::codec::OpusCodec;
    use crate::protocol::AudioPacket;
    use crate::transport::UdpAudioReceiver;

    struct CollectingSink {
        frames: Vec<Vec<i16>>,
    }

    impl PcmOutputSink for CollectingSink {
        fn play(&mut self, pcm: &[i16]) -> Result<()> {
            self.frames.push(pcm.to_vec());
            Ok(())
        }
    }

    #[test]
    fn audio_config_calculates_frame_sizes() {
        let config = AudioConfig::default();

        assert_eq!(config.samples_per_channel_per_frame(), 960);
        assert_eq!(config.samples_per_frame(), 1_920);
        assert_eq!(config.jitter_target_frames(), 4);
    }

    #[test]
    fn collecting_sink_accepts_silence_frame() {
        let mut sink = CollectingSink { frames: Vec::new() };
        let silence = vec![0_i16; AudioConfig::default().samples_per_frame()];

        sink.play(&silence).unwrap();

        assert_eq!(sink.frames.len(), 1);
        assert_eq!(sink.frames[0].len(), 1_920);
    }

    #[tokio::test]
    async fn push_packet_decodes_opus_into_sink() {
        let config = AudioConfig {
            buffer_ms: 20,
            ..AudioConfig::default()
        };
        let receiver = UdpAudioReceiver::bind("127.0.0.1:0".parse().unwrap(), b"secret".to_vec())
            .await
            .unwrap();
        let sink = CollectingSink { frames: Vec::new() };
        let mut runtime = WindowsReceiverRuntime::new(receiver, config.clone(), sink).unwrap();
        let mut codec = OpusCodec::new(config.clone()).unwrap();
        let pcm = vec![0_i16; config.samples_per_frame()];
        let payload = codec.encode_i16(&pcm).unwrap();

        let played = runtime
            .push_packet(AudioPacket {
                session_id: 1,
                sequence: 0,
                timestamp_ms: 0,
                payload,
            })
            .unwrap();

        assert_eq!(played, 1);
        assert_eq!(runtime.stats().udp_packets_received, 1);
        assert_eq!(runtime.stats().played_frames, 1);
        assert_eq!(runtime.sink.frames.len(), 1);
        assert_eq!(runtime.sink.frames[0].len(), config.samples_per_frame());
    }
}
