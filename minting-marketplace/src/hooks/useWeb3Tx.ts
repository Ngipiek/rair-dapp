import { useCallback } from 'react';
import { useSelector } from 'react-redux';
import {
  BigNumber,
  Contract,
  ContractReceipt,
  ContractTransaction
} from 'ethers';
import { JSONObject } from 'oreid-js';
import { useOreId } from 'oreid-react';

import useSwal from './useSwal';

import { RootState } from '../ducks';
import { ContractsInitialType } from '../ducks/contracts/contracts.types';
import { TUsersInitialState } from '../ducks/users/users.types';
import { rFetch } from '../utils/rFetch';

const confirmationsRequired = 2;

const useWeb3Tx = () => {
  const { currentChain, currentUserAddress } = useSelector<
    RootState,
    ContractsInitialType
  >((store) => store.contractStore);
  const { loginType } = useSelector<RootState, TUsersInitialState>(
    (store) => store.userStore
  );
  const oreId = useOreId();
  const reactSwal = useSwal();

  const handleReceipt = useCallback(
    async (transactionHash: string, callback?: (() => void) | undefined) => {
      try {
        await rFetch(`/api/transaction/${currentChain}/${transactionHash}`, {
          method: 'POST'
        });
        callback && callback();
      } catch (error) {
        console.error(error);
      }
    },
    [currentChain]
  );

  const handleWeb3Error = (
    errorMessage: any,
    defaultError: string | undefined = undefined
  ) => {
    //console.log('Reason:', errorMessage.reason)
    //console.log('Code', errorMessage.code)
    //console.log('Error', errorMessage.error)
    //console.log('Method', errorMessage.method)
    //console.log('Transaction', errorMessage.transaction);

    let cleanError = '';

    if (errorMessage.cancelled) {
      cleanError = 'The transaction has been cancelled!';
    } else if (
      errorMessage?.transaction?.blockNumber === null &&
      errorMessage?.receipt?.status === 0
    ) {
      cleanError = 'The transaction has failed on the blockchain';
    } else if (errorMessage.receipt) {
      //console.info('Repriced');
      handleReceipt(errorMessage.receipt);
      return true;
    }

    // Attempt #1: Smart Contract Error
    // Will have a readable revert message for the user
    if (!cleanError) {
      if (
        errorMessage?.error?.message &&
        !errorMessage.error.message.includes('0x')
      ) {
        cleanError = errorMessage?.error?.message;
      }
    }
    if (!cleanError) {
      cleanError = errorMessage?.data?.message;
    }

    // Attempt #2: Frontend Error
    // An error from sending the data to the blockchain
    if (!cleanError) {
      cleanError = errorMessage.reason;
    }

    // Attempt #3: Mid-Processing Error
    // Huge message that needs to be cleaned up
    if (!cleanError) {
      cleanError = errorMessage?.message;
      if (!cleanError) {
        cleanError = errorMessage
          ?.toString()
          ?.split("'message':'execution reverted: ")
          ?.at(1)
          ?.split("'")
          ?.at(0);
      }
    }

    // Last Attempt: Default Error Message
    if (
      !cleanError ||
      cleanError?.includes('=') ||
      cleanError?.includes('0x')
    ) {
      cleanError = defaultError
        ? defaultError
        : 'An unexpected error has ocurred on your transaction, please try again later.';
    }

    reactSwal.fire('Error', cleanError, 'error');
    return false;
  };

  const metamaskCall = async (
    contract: Contract,
    method: string,
    args: any[],
    options?: {
      failureMessage?: string;
      callback?: () => void;
    }
  ) => {
    let paramsValidation: ContractTransaction;
    try {
      paramsValidation = await contract[method](...args);
    } catch (errorMessage) {
      return handleWeb3Error(errorMessage, options?.failureMessage);
    }
    if (paramsValidation?.wait) {
      let transactionReceipt: ContractReceipt;
      try {
        transactionReceipt = await paramsValidation.wait(confirmationsRequired);
      } catch (errorMessage) {
        return handleWeb3Error(errorMessage, options?.failureMessage);
      }
      if (transactionReceipt && transactionReceipt.blockNumber) {
        handleReceipt(transactionReceipt.transactionHash, options?.callback);
      }
      return true;
    }
    return paramsValidation;
  };

  const oreIdCall = async (
    contract: Contract,
    method: string,
    args: any[],
    options?: {
      failureMessage?: string;
      callback?: () => void;
    }
  ) => {
    if (!oreId.isInitialized) {
      reactSwal.fire('OreID error', 'Please login', 'error');
    }
    // Use the Ethers contract to populate the transaction
    const transactionBody = await contract.populateTransaction[method](...args);
    /*
    Used for debugging
    const userBalance = await contract.provider.getBalance(
      contract.signer.getAddress()
    );
    */

    const methodsFound = Object.keys(contract.interface.functions).find(
      (item) => item.includes(`${method}(`)
    );
    if (
      methodsFound &&
      contract.interface.functions[methodsFound].stateMutability === 'view'
    ) {
      // If the method is a view function, query the info directly through Ethers
      return await contract[method](...args);
    }
    if (args.length && args.at(-1).value) {
      let estimatedGas;
      try {
        estimatedGas = await contract.estimateGas[method](...args);
      } catch (error) {
        return handleWeb3Error(error);
      }
      const totalValue = BigNumber.from(args.at(-1).value).add(estimatedGas);
      args[args.length - 1] = {
        value: totalValue.toString()
      };
    }
    const userChainAccounts = oreId.auth.user.data.chainAccounts;
    // Find the ETH public address
    const ethAccount = userChainAccounts.find((account) =>
      account.chainNetwork.includes('eth')
    );
    if (!ethAccount) {
      reactSwal.fire('Error', 'No accounts found', 'error');
      return;
    }
    // Cleanup any BigNumber values (convert to string)
    const convertedTransactionBody: JSONObject = {};
    Object.keys(transactionBody).forEach((key) => {
      convertedTransactionBody[key] = transactionBody[key]._isBigNumber
        ? transactionBody[key].toString()
        : transactionBody[key];
    });
    convertedTransactionBody.from = ethAccount.chainAccount;
    try {
      const transaction = await oreId.createTransaction({
        transaction: convertedTransactionBody,
        chainAccount: ethAccount.chainAccount,
        chainNetwork: ethAccount.chainNetwork,
        signOptions: {
          broadcast: true
        }
      });
      // launch popup to have the user approve signature
      const response = await oreId.popup.sign({ transaction });
      if (response.transactionId) {
        await contract.provider.waitForTransaction(
          response.transactionId,
          confirmationsRequired
        );
        handleReceipt(response.transactionId, options?.callback);
        return true;
      } else {
        return false;
      }
    } catch (error) {
      console.error(error);
      reactSwal.fire('Error', 'An error has occurred', 'error');
      return false;
    }
  };

  return {
    web3TxHandler: (
      contract: Contract,
      method: string,
      args: any[] = [],
      options?: {
        failureMessage?: string;
        callback?: () => void;
      }
    ) => {
      if (!currentUserAddress) {
        console.error(
          `Web3 method call ${method} will not be called without login`
        );
        return;
      }
      switch (loginType) {
        case 'oreid':
          return oreIdCall(contract, method, args, options);
        case 'metamask':
          return metamaskCall(contract, method, args, options);
        default:
          reactSwal.fire('Error', 'Please login', 'error');
      }
    }
  };
};

export default useWeb3Tx;
