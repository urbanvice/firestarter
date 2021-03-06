#!/bin/bash
source params.sh
rm -rf ~/eosio-wallet

# Helper functions
kill() {
  if [ -f $ME/nodeos.pid ]; then
    kill `cat $ME/nodeos.pid`
    rm -f $ME/nodeos.pid
  fi
}

error() {
  echo "ERROR: $@"
  kill
  exit -1
}

warn() {
  echo "WARN: $@"
}

runcmd() {
  echo "> $@"
  r=-1
  while [ $r -ne 0 ]; do
    $@
    r=$?
    if [ $r -ne 0 ]; then
      echo "FAILED ... retrying"
      sleep 1
    fi
  done
  echo
}

echo "How many accounts you want to inject from ERC20 snapshot?"
select yn in "1" "1000" "5000" "30000" "All"; do
    case $yn in
        "1" ) ACCOUNTS_TO_INJECT=1; break;;
        "1000" ) ACCOUNTS_TO_INJECT=1000; break;;
        "5000" ) ACCOUNTS_TO_INJECT=5000; break;;
        "3000" ) ACCOUNTS_TO_INJECT=30000; break;;
        "All" ) ACCOUNTS_TO_INJECT=0; break;;
    esac
done      

#We clear everything
./shutdown.sh
./clear.sh

killall keosd > /dev/null 2>&1
killall nodeos > /dev/null 2>&1

#Launch nodeos
./launch.sh &

echo "Waiting for nodeos to start ...."
sleep 3

# Create wallet
tmp=$(mktemp)
cleos wallet create > $tmp
if [[ "$?" != "0" ]]; then
  error "Unable to create wallet (remove default.wallet)"
fi
cat $tmp | tail -n1 > $ME/data/.wallet-pass

# Import privkeys keys
runcmd cleos wallet import $EOSIO_PRIV

# Create System accounts
for account in  $SYSTEM_ACCOUNTS;do
  runcmd cleos create account eosio $account $EOSIO_PUB
done

# Set contracts code
runcmd cleos set contract eosio.msig  $CONTRACT_FOLDER/eosio.msig
runcmd cleos set contract eosio.token $CONTRACT_FOLDER/eosio.token

## Load bios contract
runcmd cleos set contract eosio $CONTRACT_FOLDER/eosio.bios

# Issue to eosio
echo '[ "eosio","'$EOS_CREATE'"]' > $tmp
runcmd cleos push action eosio.token create $tmp -p eosio.token
echo '["eosio","'$EOS_ISSUE'", "'$MEMO'"]' > $tmp
runcmd cleos push action eosio.token issue $tmp -p eosio

# Creating initial ABP accounts
# Import keys from folder,set env vars and create accounts
for filename in $(ls -1 $ME/producers/*.key 2> /dev/null); do
  name=$(basename $filename)
  account="${name%.*}"

  account_pub="${account}_pub"
  account_priv="${account}_priv"
  declare $account_priv=$(head -n1 $filename | awk '{n=split($0,a," "); print a[n];}')
  declare $account_pub=$(tail -n1 $filename)
  runcmd cleos create account eosio $account $(tail -n1 $filename) $(tail -n1 $filename)
done

# Create prods.json file
echo > $tmp
echo '{"schedule":[' >> $tmp

# Create producers accounts
for filename in $(ls -1 $ME/producers/*.key 2> /dev/null); do
  name=$(basename $filename)
  bp_account="${name%.*}"
  account_pub=$(tail -n1 $filename)
  echo '{"producer_name":"'$bp_account'","block_signing_key": "'$account_pub'"}' >> $tmp
done
echo ']}' >> $tmp

# Set producers
runcmd cleos push action eosio setprods $tmp -p eosio

# Set system
runcmd cleos set contract  eosio $CONTRACT_FOLDER/eosio.system -p eosio

# Privilegios
echo '["eosio.msig", 1]'> $tmp
runcmd cleos push action eosio setpriv $tmp -p eosio@active

# Inject ERC20 snapshot into the running nodeos
clear
cd $ME/../inject
python injector.py --csv-balance $ME/../validator/this/snapshot.csv \
   --accounts-per-tx $ACCOUNTS_PER_TX --core-symbol $CORE_SYMBOL \
   --accounts-to-inject $ACCOUNTS_TO_INJECT
if [[ $? -ne 0 ]]; then
  echo "There were errors ^^^^"
  exit
fi
cd -

#TODO add b1 additional liquid issued as param
cleos push action eosio.token issue '["b1", "10.0000 EOS", "memo"]' -p eosio

#RESIGN ACCOUNTS
echo  '{"account": "eosio", "permission": "active", "parent": "owner", "auth":{"threshold": 1, "keys": [], "waits": [], "accounts": [{"weight": 1, "permission": {"actor": "eosio.prods", "permission": active}}]}}' > $tmp 
runcmd cleos push action eosio updateauth $tmp -p eosio@active
echo '{"account": "eosio", "permission": "owner", "parent": "", "auth":{"threshold": 1, "keys": [], "waits": [], "accounts": [{"weight": 1, "permission": {"actor": "eosio.prods", "permission": active}}]}}' > $tmp
runcmd cleos push action eosio updateauth $tmp -p eosio@owner

for account in  $SYSTEM_ACCOUNTS;do
  echo  '{"account": "'$account'", "permission": "active", "parent": "owner", "auth":{"threshold": 1, "keys": [], "waits": [], "accounts": [{"weight": 1, "permission": {"actor": "eosio", "permission": active}}]}}' > $tmp 
  runcmd cleos push action eosio updateauth $tmp -p $account@active
  echo '{"account": "'$account'", "permission": "owner", "parent": "", "auth":{"threshold": 1, "keys": [], "waits": [], "accounts": [{"weight": 1, "permission": {"actor": "eosio", "permission": active}}]}}' > $tmp
  runcmd cleos push action eosio updateauth $tmp -p $account@owner
done

./watch.sh
