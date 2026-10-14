// SPDX-License-Identifier: MIT
// Copyright 2026 Ryan Murray <ryan@aurorasilicon.org>
fn main() {
    let header = [0x33,0x56,0x56,0x4e,0,0,1,0,1,0,0,0,0xfe,0x5a,1,0,0,0x40,0,0,0,0xc0,0,0];
    for banks in [16, 29] {
        let mut data = vec![0xffu8; banks * 0x10000];
        data[..24].copy_from_slice(&header);
        let original = data.clone();
        assert!(apple_nvram::v3::Nvram::parse(&data).is_ok());
        assert_eq!(data, original);
        let invalid = vec![0xffu8; banks * 0x10000];
        assert!(apple_nvram::v3::Nvram::parse(&invalid).is_err());
    }
    println!("16/29-bank valid and invalid immutable-memory parser controls PASS; no device I/O or writer");
}
