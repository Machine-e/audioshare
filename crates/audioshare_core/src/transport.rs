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
        let encoded = packet.encode(&self.key);
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
        let (len, _) = self.socket.recv_from(&mut buf).await.context("recv audio packet")?;
        AudioPacket::decode(&self.key, &buf[..len]).context("decode audio packet")
    }
}
