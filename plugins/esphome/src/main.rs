//! Afzonderlijk hostproces voor ESPHome.
fn main() -> std::process::ExitCode {
    stulp_plugin_host::run(stulp_esphome::Esphome::default)
}
