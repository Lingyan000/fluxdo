//! QUIC interop runner server endpoint.

use clap::Parser;
use rama_quic_interop_runner::{init_tracing, server, testcase_or_exit};
use std::process::ExitCode;

#[tokio::main]
async fn main() -> ExitCode {
    let args = server::Args::parse();
    let testcase = match testcase_or_exit(&args.testcase) {
        Ok(testcase) => testcase,
        Err(code) => return code,
    };
    if !testcase.server_supported() {
        eprintln!("unsupported TESTCASE for server: {}", args.testcase);
        return ExitCode::from(127);
    }
    if args.check_testcase {
        return ExitCode::SUCCESS;
    }
    init_tracing();
    match server::run(args, testcase).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("server failed: {error:?}");
            ExitCode::FAILURE
        }
    }
}
