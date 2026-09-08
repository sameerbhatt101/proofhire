use alloy::{
    primitives::B256,
    providers::{Provider, ProviderBuilder, WsConnect},
    rpc::types::{BlockTransactionsKind, TransactionReceipt},
};

use anyhow::Result;
use clap::Parser;
use futures_util::StreamExt;
use hex;

use std::env;
use std::fs;
use std::str::FromStr;
use std::time::SystemTime;

use usc_abi_encoding::abi::abi_encode;
use usc_abi_encoding::common::EncodingVersion;

#[derive(Parser, Debug)]
#[command(name = "encode-blocks")]
pub struct CliArguments {
    #[arg(long, help = "WebSockets URL to an Ethereum RPC", required = true)]
    pub eth_rpc_url: String,

    #[arg(long, help = "Directory path to store JSON files", required = true)]
    pub path_to_store_json: String,
}

async fn encode_transaction(
    provider: impl Provider,
    tx_hash_str: &str,
    rx_or_none: Option<TransactionReceipt>,
) -> Option<String> {
    let tx_hash = B256::from_str(tx_hash_str).unwrap();

    let tx = match provider.get_transaction_by_hash(tx_hash).await {
        Ok(Some(tx)) => tx,
        Ok(None) => {
            println!("    skipping tx {tx_hash_str}: transaction not found via RPC");
            return None;
        }
        Err(e) => {
            println!("    skipping tx {tx_hash_str}: get_transaction_by_hash failed: {e}");
            return None;
        }
    };

    let rx = match rx_or_none {
        Some(rx) => rx,
        None => match provider.get_transaction_receipt(tx_hash).await {
            Ok(Some(rx)) => rx,
            Ok(None) => {
                println!("    skipping tx {tx_hash_str}: receipt not found via RPC");
                return None;
            }
            Err(e) => {
                println!("    skipping tx {tx_hash_str}: get_transaction_receipt failed: {e}");
                return None;
            }
        },
    };

    let encoded_data = abi_encode(tx, rx, EncodingVersion::V1).unwrap();
    let as_str = hex::encode(encoded_data.abi());

    Some(format!("0x{}", as_str))
}

async fn encode_and_write_to_disk(
    path: String,
    provider: impl Provider,
    block_number: u64,
    tx_hash: String,
    rx_or_none: Option<TransactionReceipt>,
) {
    let Some(encoded_data) = encode_transaction(provider, &tx_hash.to_string(), rx_or_none).await
    else {
        // RPC returned None for this transaction (e.g. transient reorg or
        // unindexed tx); skip it rather than writing anything to disk.
        return;
    };

    // <path>/<block_num>/<tx_hash>.txt
    fs::write(
        format!("{}/{}/{}.txt", path, block_number, tx_hash.to_string()),
        encoded_data + "\n",
    )
    .unwrap();
}

async fn block_handler(
    provider: impl Provider + Clone + 'static,
    block_number: u64,
    path_to_store_json: String,
) -> Result<()> {
    println!("new block --- {:?}", block_number);

    fs::create_dir_all(format!("{}/{}", path_to_store_json, block_number))?;

    // Retry the block fetch up to 5 times with a 1s delay; the node may not
    // have the block indexed yet at the moment we get notified.
    const MAX_ATTEMPTS: u32 = 5;
    const RETRY_DELAY: std::time::Duration = std::time::Duration::from_secs(1);
    let mut block = None;
    let mut last_err: Option<anyhow::Error> = None;
    for attempt in 1..=MAX_ATTEMPTS {
        match provider
            .get_block_by_number(block_number.into(), BlockTransactionsKind::Full)
            .await
        {
            Ok(Some(b)) => {
                block = Some(b);
                break;
            }
            Ok(None) => {
                last_err = Some(anyhow::anyhow!(
                    "block {block_number} not found (attempt {attempt}/{MAX_ATTEMPTS})"
                ));
            }
            Err(e) => {
                last_err = Some(anyhow::anyhow!(
                    "failed to fetch block {block_number} (attempt {attempt}/{MAX_ATTEMPTS}): {e}"
                ));
            }
        }
        if attempt < MAX_ATTEMPTS {
            println!("    retrying block --- {block_number} (attempt {attempt}/{MAX_ATTEMPTS})");
            tokio::time::sleep(RETRY_DELAY).await;
        }
    }
    let block = block.ok_or_else(|| {
        last_err.unwrap_or_else(|| anyhow::anyhow!("failed to fetch block {block_number}"))
    })?;

    let tx_hashes = block.transactions.hashes();

    if tx_hashes.len() >= 13 {
        // optimize RPC cost by fetching all receipts at once
        let receipts = provider
            .get_block_receipts(block_number.into())
            .await?
            .unwrap();
        let tasks: Vec<_> = receipts
            .into_iter()
            .map(|rcp| {
                tokio::spawn({
                    let prv = provider.clone();
                    let path = path_to_store_json.clone();
                    async move {
                        encode_and_write_to_disk(
                            path.clone(),
                            prv.clone(),
                            block_number,
                            rcp.transaction_hash.to_string(),
                            Some(rcp),
                        )
                        .await;
                    }
                })
            })
            .collect();

        for task in tasks {
            task.await.unwrap();
        }
    } else {
        // loop over each transaction and fetch its receipt via explicit RPC call
        let tasks: Vec<_> = tx_hashes
            .clone()
            .into_iter()
            .map(|tx_hash| {
                tokio::spawn({
                    let prv = provider.clone();
                    let path = path_to_store_json.clone();
                    async move {
                        encode_and_write_to_disk(
                            path.clone(),
                            prv.clone(),
                            block_number,
                            tx_hash.to_string(),
                            None,
                        )
                        .await;
                    }
                })
            })
            .collect();

        for task in tasks {
            task.await.unwrap();
        }
    }

    println!(
        "<<< done encoding {:?} transactions in block {:?}",
        tx_hashes.len(),
        block_number
    );

    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = CliArguments::parse();

    let start = SystemTime::now();
    let timeout_minutes: u64 = env::var("TIMEOUT_MINUTES").unwrap_or("2".into()).parse()?;
    println!("=== starting with timeout {:?} mins ...", timeout_minutes);

    fs::create_dir_all(args.path_to_store_json.clone())?;

    let provider = ProviderBuilder::new()
        .on_ws(WsConnect::new(args.eth_rpc_url))
        .await?;

    let subscriber = provider.subscribe_blocks().await?;
    let mut stream = subscriber.into_stream();
    let mut last_seen_block: Option<u64> = None;
    while let Some(block) = stream.next().await {
        if last_seen_block == Some(block.number) {
            println!(
                "    skipping duplicate notification for block --- {:?}",
                block.number
            );
            continue;
        }
        last_seen_block = Some(block.number);

        let _ = block_handler(
            provider.clone(),
            block.number,
            args.path_to_store_json.clone(),
        )
        .await;

        let current = start.elapsed()?;
        if current.as_secs() >= timeout_minutes * 60 {
            println!(
                "=== {:?} mins timeout reached. exiting ...",
                timeout_minutes
            );
            break;
        }
    }

    Ok(())
}
