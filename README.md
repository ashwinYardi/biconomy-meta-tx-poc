# biconomy-meta-tx-poc

A friendly project to demo how to configure and use biconomy's relayer for gasless meta transactions

## How to use the POC

1. Install dependencies via command `npm install`

2. Create .env file by copying  `.env.example` and fill out the relevant values.

3. Compile the contract by running: `npx hardhat compile`

4. Deploy the farm contract using: `npm run deployFarm:test`

   **The current version uses farm contract deployed here: `0x4Cb1f46a657013194c94f72f4376DB20E64A583E`**

5. Add pool in a farm contract so that we can test **deposit(0,0)** via meta transactions.

6. Open, `POC.html` and change line number 17 and 18 respectively to add deployed contract address and abi ( if needed ).

7. To serve the html, run `npm start` and go to `http://127.0.0.1:8080/` in browser ( with metamask enabled).

8. Choose `POC.html` to serve and enjoy!

9. You might want to check the console for details and insights.

## Configuring Biconomy dashboard

Just follow this link: https://docs.biconomy.io/products/enable-gasless-transactions/custom-implementation/dashboard

This covers entire flow end to end.
