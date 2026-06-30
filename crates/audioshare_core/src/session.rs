use rand::{distributions::Uniform, Rng};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PairingCode(String);

impl PairingCode {
    pub fn generate() -> Self {
        let mut rng = rand::thread_rng();
        let digit = Uniform::new_inclusive(0_u8, 9);
        let digits: String = (0..6)
            .map(|_| char::from(b'0' + rng.sample(digit)))
            .collect();
        Self(format!("{}-{}", &digits[..3], &digits[3..]))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn matches(&self, user_input: &str) -> bool {
        normalize_code(user_input) == normalize_code(&self.0)
    }
}

fn normalize_code(value: &str) -> String {
    value.chars().filter(|c| c.is_ascii_digit()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pairing_code_accepts_hyphen_or_plain_digits() {
        let code = PairingCode("123-456".to_string());
        assert!(code.matches("123456"));
        assert!(code.matches("123-456"));
        assert!(!code.matches("654321"));
    }
}
