import { JsonRpcApiProvider, TransactionResponse } from 'ethers';

export interface EncodedFields {
  types: string[];
  values: any[] | any[][];
}

// THE CODE BELOW IS USED AS A TEMPORARY FIX FOR RAW YPARITY IN TRANSACTIONS
// IT SHOULD BE REMOVED ONCE ETHERS HAS NATIVE SUPPORT FOR FETCHING RAW YPARITY ON
// TRANSACTION RESPONSES
export interface RawAuthorization {
  yParity: number;
}

export class RawTransactionResponse {
  readonly authorizationList!: null | Array<RawAuthorization>;

  constructor(authorizationList: null | Array<RawAuthorization>) {
    this.authorizationList = authorizationList;
  }
}

export class TransactionWithRaw {
  readonly formatted!: TransactionResponse;
  readonly raw!: RawTransactionResponse;

  constructor(formatted: TransactionResponse, raw: RawTransactionResponse) {
    this.formatted = formatted;
    this.raw = raw;
  }
}

/**
 * Used to extract from the raw transaction JSON the raw yparity values
 * for the authorization list. In case they exists.
 *
 * Wraps the formatted TransactionResponse along with the raw data.
 *
 * @param provider - JsonRpcApiProvider instance
 * @param txHash - Transaction hash
 * @returns TransactionWithRaw or null if not found
 */
export async function getTransactionWithRaw(
  provider: JsonRpcApiProvider,
  txHash: string,
): Promise<TransactionWithRaw | null> {
  let json: any;
  try {
    json = await provider.send('eth_getTransactionByHash', [txHash]);
  } catch (e) {
    console.error(`Error fetching transaction ${txHash}: ${(e as Error).message}`);
    return null;
  }

  if (!json) {
    return null;
  }

  const formattedTx = provider._wrapTransactionResponse(json, await provider.getNetwork());
  // We map the raw yParity values from the JSON response
  // to a numeric value in RawAuthorization array
  const rawAuthorizationList =
    json.authorizationList?.map((auth: any) => ({
      yParity: Number(auth.yParity),
    })) || null;
  const rawTx = new RawTransactionResponse(rawAuthorizationList);

  return new TransactionWithRaw(formattedTx, rawTx);
}
