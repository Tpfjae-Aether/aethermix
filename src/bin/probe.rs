use std::io::Read;
use std::process::{Command, Stdio};
use std::time::Instant;

fn main() {
    let url = std::env::args().nth(1).expect("url");
    let mut cmd = Command::new(concat!(env!("AETHER_ROOT"), "/bin/ffmpeg.exe"));
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000);
    }
    cmd.args(["-hide_banner", "-loglevel", "error", "-nostdin"]);
    cmd.args(["-i", url.as_str(), "-vn", "-ac", "2", "-ar", "44100", "-f", "s16le", "pipe:1"]);
    cmd.stdout(Stdio::piped()).stderr(Stdio::null());
    let mut child = cmd.spawn().expect("spawn");
    let mut out = child.stdout.take().unwrap();
    let mut buf = vec![0u8; 32768];
    let mut total: u64 = 0;
    let t0 = Instant::now();
    loop {
        match out.read(&mut buf) {
            Ok(0) => {
                println!("eof after {total} bytes in {:?}", t0.elapsed());
                break;
            }
            Ok(n) => {
                total += n as u64;
                println!("{:>4}ms read {n} (total {total})", t0.elapsed().as_millis());
                if total > 44100 * 2 * 20 {
                    println!("enough, stopping");
                    let _ = child.kill();
                    break;
                }
            }
            Err(e) => {
                println!("read error {e} after {total}");
                break;
            }
        }
    }
}
