use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use thiserror::Error;

pub const PROTOCOL_VERSION: u16 = 1;
pub const AUDIO_MAGIC: &[u8; 4] = b"ASH1";
pub const AUTH_TAG_LEN: usize = 16;
type HmacSha256 = Hmac<Sha256>;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum PairingState {
    Idle,
    WaitingForCode,
    Paired,
    Rejected,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum ControlMessage {
    Hello {
        protocol_version: u16,
        device_name: String,
    },
    Pair {
        code: String,
    },
    PairAccepted {
        session_id: u64,
        token_hint: String,
    },
    PairRejected {
        reason: String,
    },
    StartStream,
    StopStream,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AudioPacket {
    pub session_id: u64,
    pub sequence: u64,
    pub timestamp_ms: u64,
    pub payload: Vec<u8>,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum PacketError {
    #[error("packet is too short")]
    TooShort,
    #[error("invalid magic")]
    InvalidMagic,
    #[error("invalid protocol version")]
    InvalidProtocolVersion,
    #[error("packet length does not match payload")]
    InvalidLength,
    #[error("payload is too large")]
    PayloadTooLarge,
    #[error("authentication failed")]
    AuthFailed,
}

impl AudioPacket {
    pub fn encode(&self, key: &[u8]) -> Result<Vec<u8>, PacketError> {
        if self.payload.len() > u16::MAX as usize {
            return Err(PacketError::PayloadTooLarge);
        }
        let mut out = Vec::with_capacity(4 + 2 + 8 + 8 + 8 + 2 + self.payload.len() + AUTH_TAG_LEN);
        out.extend_from_slice(AUDIO_MAGIC);
        out.extend_from_slice(&PROTOCOL_VERSION.to_be_bytes());
        out.extend_from_slice(&self.session_id.to_be_bytes());
        out.extend_from_slice(&self.sequence.to_be_bytes());
        out.extend_from_slice(&self.timestamp_ms.to_be_bytes());
        out.extend_from_slice(&(self.payload.len() as u16).to_be_bytes());
        out.extend_from_slice(&self.payload);
        let tag = auth_tag(key, &out);
        out.extend_from_slice(&tag[..AUTH_TAG_LEN]);
        Ok(out)
    }

    pub fn decode(key: &[u8], bytes: &[u8]) -> Result<Self, PacketError> {
        const HEADER_LEN: usize = 4 + 2 + 8 + 8 + 8 + 2;
        if bytes.len() < HEADER_LEN + AUTH_TAG_LEN {
            return Err(PacketError::TooShort);
        }
        if &bytes[0..4] != AUDIO_MAGIC {
            return Err(PacketError::InvalidMagic);
        }
        let protocol_version = u16::from_be_bytes(bytes[4..6].try_into().expect("slice length"));
        if protocol_version != PROTOCOL_VERSION {
            return Err(PacketError::InvalidProtocolVersion);
        }
        let session_id = u64::from_be_bytes(bytes[6..14].try_into().expect("slice length"));
        let sequence = u64::from_be_bytes(bytes[14..22].try_into().expect("slice length"));
        let timestamp_ms = u64::from_be_bytes(bytes[22..30].try_into().expect("slice length"));
        let payload_len =
            u16::from_be_bytes(bytes[30..32].try_into().expect("slice length")) as usize;
        let expected_len = HEADER_LEN + payload_len + AUTH_TAG_LEN;
        if bytes.len() != expected_len {
            return Err(PacketError::InvalidLength);
        }

        let body_len = bytes.len() - AUTH_TAG_LEN;
        let expected = auth_tag(key, &bytes[..body_len]);
        if bytes[body_len..] != expected[..AUTH_TAG_LEN] {
            return Err(PacketError::AuthFailed);
        }
        let payload = bytes[32..32 + payload_len].to_vec();
        Ok(Self {
            session_id,
            sequence,
            timestamp_ms,
            payload,
        })
    }
}

fn auth_tag(key: &[u8], bytes: &[u8]) -> Vec<u8> {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(bytes);
    mac.finalize().into_bytes().to_vec()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn audio_packet_round_trips_with_authentication() {
        let packet = AudioPacket {
            session_id: 7,
            sequence: 42,
            timestamp_ms: 1234,
            payload: vec![1, 2, 3, 4],
        };
        let encoded = packet.encode(b"secret").unwrap();
        assert_eq!(AudioPacket::decode(b"secret", &encoded).unwrap(), packet);
        assert_eq!(
            AudioPacket::decode(b"wrong", &encoded).unwrap_err(),
            PacketError::AuthFailed
        );
    }

    #[test]
    fn audio_packet_rejects_mismatched_payload_length() {
        let packet = AudioPacket {
            session_id: 7,
            sequence: 42,
            timestamp_ms: 1234,
            payload: vec![1, 2, 3, 4],
        };

        let mut encoded = packet.encode(b"secret").unwrap();
        encoded.push(0);
        assert_eq!(
            AudioPacket::decode(b"secret", &encoded).unwrap_err(),
            PacketError::InvalidLength
        );
    }
}
