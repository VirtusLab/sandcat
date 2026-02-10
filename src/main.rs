fn main() {
    let body = reqwest::blocking::get("https://example.org")
        .expect("failed to send request")
        .text()
        .expect("failed to read response body");
    println!("{body}");
}
