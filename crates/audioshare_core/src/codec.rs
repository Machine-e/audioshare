use crate::audio::AudioConfig;
use anyhow::{Context, Result};

pub struct OpusCodec {
    encoder: opus::Encoder,
    decoder: opus::Decoder,
    config: AudioConfig,
}

impl OpusCodec {
    pub fn new(config: AudioConfig) -> Result<Self> {
        let channels = match config.channels {
            1 => opus::Channels::Mono,
            2 => opus::Channels::Stereo,
            other => anyhow::bail!("unsupported channel count: {other}"),
        };
        let mut encoder =
            opus::Encoder::new(config.sample_rate, channels, opus::Application::Audio)
                .context("create opus encoder")?;
        encoder
            .set_bitrate(opus::Bitrate::Bits(config.bitrate_kbps as i32 * 1000))
            .context("set opus bitrate")?;
        let decoder =
            opus::Decoder::new(config.sample_rate, channels).context("create opus decoder")?;
        Ok(Self {
            encoder,
            decoder,
            config,
        })
    }

    pub fn encode_i16(&mut self, pcm: &[i16]) -> Result<Vec<u8>> {
        let mut output = vec![0_u8; 4096];
        let len = self
            .encoder
            .encode(pcm, &mut output)
            .context("encode opus frame")?;
        output.truncate(len);
        Ok(output)
    }

    pub fn decode_i16(&mut self, packet: &[u8]) -> Result<Vec<i16>> {
        let samples_per_channel =
            self.config.sample_rate as usize * self.config.frame_ms as usize / 1000;
        let mut output = vec![0_i16; samples_per_channel * self.config.channels as usize];
        let len = self
            .decoder
            .decode(packet, &mut output, false)
            .context("decode opus frame")?;
        output.truncate(len * self.config.channels as usize);
        Ok(output)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opus_codec_round_trips_one_pcm_frame() {
        let config = AudioConfig::default();
        let mut codec = OpusCodec::new(config.clone()).unwrap();
        let pcm = vec![0_i16; config.samples_per_frame()];

        let encoded = codec.encode_i16(&pcm).unwrap();
        let decoded = codec.decode_i16(&encoded).unwrap();

        assert!(!encoded.is_empty());
        assert_eq!(decoded.len(), config.samples_per_frame());
    }
}
