use crate::protocol::AudioPacket;
use std::collections::BTreeMap;

#[derive(Debug, PartialEq, Eq)]
pub enum JitterPop {
    Packet(AudioPacket),
    Missing { sequence: u64 },
    NotReady,
}

#[derive(Debug)]
pub struct JitterBuffer {
    target_depth: usize,
    next_sequence: Option<u64>,
    buffered: bool,
    packets: BTreeMap<u64, AudioPacket>,
}

impl JitterBuffer {
    pub fn new(target_depth: usize) -> Self {
        Self {
            target_depth: target_depth.max(1),
            next_sequence: None,
            buffered: false,
            packets: BTreeMap::new(),
        }
    }

    pub fn push(&mut self, packet: AudioPacket) {
        if self
            .next_sequence
            .is_some_and(|next_sequence| self.buffered && packet.sequence < next_sequence)
        {
            return;
        }
        self.next_sequence = Some(self.next_sequence.map_or(packet.sequence, |next_sequence| {
            next_sequence.min(packet.sequence)
        }));
        self.packets.insert(packet.sequence, packet);
    }

    pub fn pop_ready(&mut self) -> Option<AudioPacket> {
        match self.pop_next() {
            JitterPop::Packet(packet) => Some(packet),
            JitterPop::Missing { .. } | JitterPop::NotReady => None,
        }
    }

    pub fn pop_next(&mut self) -> JitterPop {
        let Some(next) = self.next_sequence else {
            return JitterPop::NotReady;
        };
        if !self.buffered {
            if self.packets.len() < self.target_depth {
                return JitterPop::NotReady;
            }
            self.buffered = true;
        }

        if let Some(packet) = self.packets.remove(&next) {
            self.next_sequence = Some(next.saturating_add(1));
            return JitterPop::Packet(packet);
        }

        if self.packets.keys().any(|sequence| *sequence > next) {
            self.next_sequence = Some(next.saturating_add(1));
            return JitterPop::Missing { sequence: next };
        }

        JitterPop::NotReady
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

    #[test]
    fn reports_missing_packet_after_target_depth() {
        let mut buffer = JitterBuffer::new(2);
        buffer.push(packet(10));
        buffer.push(packet(12));

        assert_eq!(buffer.pop_next(), JitterPop::Packet(packet(10)));
        assert_eq!(buffer.pop_next(), JitterPop::Missing { sequence: 11 });
        assert_eq!(buffer.pop_next(), JitterPop::Packet(packet(12)));
        assert_eq!(buffer.pop_next(), JitterPop::NotReady);
    }

    #[test]
    fn waits_for_initial_target_depth_before_playback() {
        let mut buffer = JitterBuffer::new(2);
        buffer.push(packet(1));

        assert_eq!(buffer.pop_next(), JitterPop::NotReady);

        buffer.push(packet(2));
        assert_eq!(buffer.pop_next(), JitterPop::Packet(packet(1)));
    }

    #[test]
    fn ignores_late_duplicate_packets() {
        let mut buffer = JitterBuffer::new(1);
        buffer.push(packet(1));
        assert_eq!(buffer.pop_next(), JitterPop::Packet(packet(1)));

        buffer.push(packet(1));
        assert_eq!(buffer.pop_next(), JitterPop::NotReady);
    }
}
