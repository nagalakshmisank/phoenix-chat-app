use std::path::Path;
use std::io::Write;

fn main() {
  // Generate icon.ico if it doesn't exist
  let icon_dir = Path::new("icons");
  let icon_path = icon_dir.join("icon.ico");

  if !icon_path.exists() {
    std::fs::create_dir_all(icon_dir).ok();

    // Create a minimal valid 32x32 ICO file
    let ico_data = create_ico_data();
    if let Ok(mut file) = std::fs::File::create(&icon_path) {
      let _ = file.write_all(&ico_data);
    }
  }

  tauri_build::build();
}

fn create_ico_data() -> Vec<u8> {
  let mut data = Vec::new();

  // ICONHEADER
  data.extend_from_slice(&[0x00, 0x00]); // Reserved
  data.extend_from_slice(&[0x01, 0x00]); // Type = ICO
  data.extend_from_slice(&[0x01, 0x00]); // Count = 1

  // ICONDIRENTRY
  data.push(32);                          // Width
  data.push(32);                          // Height
  data.push(0);                           // ColorCount
  data.push(0);                           // Reserved
  data.extend_from_slice(&[0x01, 0x00]); // Planes
  data.extend_from_slice(&[0x20, 0x00]); // BitsPerPixel = 32
  data.extend_from_slice(&[0x68, 0x10, 0x00, 0x00]); // BytesInImage = 4200
  data.extend_from_slice(&[0x16, 0x00, 0x00, 0x00]); // Offset = 22

  // BMP INFOHEADER
  data.extend_from_slice(&[0x28, 0x00, 0x00, 0x00]); // Size = 40
  data.extend_from_slice(&[0x20, 0x00, 0x00, 0x00]); // Width = 32
  data.extend_from_slice(&[0x40, 0x00, 0x00, 0x00]); // Height = 64
  data.extend_from_slice(&[0x01, 0x00]);             // Planes = 1
  data.extend_from_slice(&[0x20, 0x00]);             // Bits = 32
  data.extend_from_slice(&[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
  data.extend_from_slice(&[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
  data.extend_from_slice(&[0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);

  // Pixel data: 32x32 purple pixels (BGRA)
  for _ in 0..1024 {
    data.push(0xEA); // B
    data.push(0x7E); // G
    data.push(0x66); // R
    data.push(0xFF); // A
  }

  // AND mask
  for _ in 0..128 {
    data.push(0x00);
  }

  data
}
