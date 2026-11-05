//! QUIC interop runner client endpoint.

use clap::Parser;
use rama_quic_interop_runner::{client, init_tracing, testcase_or_exit};
use std::process::ExitCode;

#[tokio::main]
async fn main() -> ExitCode {
    let args = client::Args::parse();
    let testcase = match testcase_or_exit(&args.testcase) {
        Ok(testcase) => testcase,
        Err(code) => return code,
    };
    if !testcase.client_supported() {
        eprintln!(
            "unsupported TESTCASE for this client build: {}",
            args.testcase
        );
        return ExitCode::from(127);
    }
    if args.check_testcase {
        return ExitCode::SUCCESS;
    }
    init_tracing();
    match client::run(args, testcase).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("client failed: {error:?}");
            ExitCode::FAILURE
        }
    }
}
