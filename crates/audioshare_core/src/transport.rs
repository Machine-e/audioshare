use crate::protocol::AudioPacket;
use anyhow::{Context, Result};
use std::net::SocketAddr;
use tokio::net::UdpSocket;

pub struct UdpAudioSender {
    socket: UdpSocket,
    peer: SocketAddr,
    key: Vec<u8>,
}

impl UdpAudioSender {
    pub async fn bind(local: SocketAddr, peer: SocketAddr, key: Vec<u8>) -> Result<Self> {
        let socket = UdpSocket::bind(local).await.context("bind UDP sender")?;
        Ok(Self { socket, peer, key })
    }

    pub async fn send(&self, packet: &AudioPacket) -> Result<usize> {
        let encoded = packet.encode(&self.key).context("encode audio packet")?;
        self.socket
            .send_to(&encoded, self.peer)
            .await
            .context("send audio packet")
    }
}

pub struct UdpAudioReceiver {
    socket: UdpSocket,
    key: Vec<u8>,
}

impl UdpAudioReceiver {
    pub async fn bind(local: SocketAddr, key: Vec<u8>) -> Result<Self> {
        let socket = UdpSocket::bind(local).await.context("bind UDP receiver")?;
        Ok(Self { socket, key })
    }

    pub async fn recv(&self) -> Result<AudioPacket> {
        let mut buf = vec![0_u8; 4096];
        let (len, _) = self
            .socket
            .recv_from(&mut buf)
            .await
            .context("recv audio packet")?;
        AudioPacket::decode(&self.key, &buf[..len]).context("decode audio packet")
    }

    pub fn local_addr(&self) -> Result<SocketAddr> {
        self.socket
            .local_addr()
            .context("query UDP receiver address")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn udp_sender_receiver_round_trips_authenticated_packet() {
        let key = b"secret".to_vec();
        let receiver = UdpAudioReceiver::bind("127.0.0.1:0".parse().unwrap(), key.clone())
            .await
            .unwrap();
        let sender = UdpAudioSender::bind(
            "127.0.0.1:0".parse().unwrap(),
            receiver.local_addr().unwrap(),
            key,
        )
        .await
        .unwrap();
        let packet = AudioPacket {
            session_id: 9,
            sequence: 3,
            timestamp_ms: 60,
            payload: vec![1, 2, 3],
        };

        sender.send(&packet).await.unwrap();
        let received = receiver.recv().await.unwrap();

        assert_eq!(received, packet);
    }
}
