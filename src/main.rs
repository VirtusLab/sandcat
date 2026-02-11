fn main() {
    let body = reqwest::blocking::get("https://softwaremill.com")
        .expect("failed to send request")
        .text()
        .expect("failed to read response body");
    println!("{body}");
}
