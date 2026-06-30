use crate::protocol::AudioPacket;
use std::collections::BTreeMap;

#[derive(Debug)]
pub struct JitterBuffer {
    target_depth: usize,
    next_sequence: Option<u64>,
    packets: BTreeMap<u64, AudioPacket>,
}

impl JitterBuffer {
    pub fn new(target_depth: usize) -> Self {
        Self {
            target_depth: target_depth.max(1),
            next_sequence: None,
            packets: BTreeMap::new(),
        }
    }

    pub fn push(&mut self, packet: AudioPacket) {
        self.next_sequence.get_or_insert(packet.sequence);
        self.packets.insert(packet.sequence, packet);
    }

    pub fn pop_ready(&mut self) -> Option<AudioPacket> {
        let next = *self.next_sequence.as_ref()?;
        if self.packets.len() < self.target_depth && !self.packets.contains_key(&next) {
            return None;
        }
        let packet = self.packets.remove(&next);
        self.next_sequence = Some(next.saturating_add(1));
        packet
    }

    pub fn len(&self) -> usize {
        self.packets.len()
    }

    pub fn is_empty(&self) -> bool {
        self.packets.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn packet(sequence: u64) -> AudioPacket {
        AudioPacket {
            session_id: 1,
            sequence,
            timestamp_ms: sequence * 20,
            payload: vec![sequence as u8],
        }
    }

    #[test]
    fn reorders_packets_by_sequence() {
        let mut buffer = JitterBuffer::new(1);
        buffer.push(packet(2));
        buffer.push(packet(1));

        assert_eq!(buffer.pop_ready().unwrap().sequence, 1);
        assert_eq!(buffer.pop_ready().unwrap().sequence, 2);
    }
}
