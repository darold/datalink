#!/bin/bash

export LANG=C
init_test () {
	echo "Initializing temporary directory for the test..."
	dropdb test_datalink 2>/dev/null
	sudo rm -rf /tmp/test_datalink
	sudo rm -rf /tmp/img2.png
	mkdir -p /tmp/test_datalink/pg_dltoken
	cp files/img1.png /tmp/test_datalink/
	cp files/img2.png /tmp/
	cp files/file*.txt /tmp/test_datalink/
	cp 'files/32391569-3aed-419f-9921-7399ecc9d980;file6.txt' /tmp/ 2>/dev/null
	sudo chown -R postgres: /tmp/img2.png
	sudo chown -R postgres: /tmp/test_datalink
	sudo chown -R postgres: '/tmp/32391569-3aed-419f-9921-7399ecc9d980;file6.txt'
	mkdir out/ 2>/dev/null
}

# Recompile and reinstall the extension
echo "Recompile and install the Datalink extension..."
cd ../
sudo make clean >/dev/null
sudo make install >/dev/null
sudo make clean >/dev/null
sudo /etc/init.d/postgresql restart
cd test/
rm -rf out/

init_test
echo "Running basic tests..."
psql -f sql/dl_basic.sql > out/dl_basic.out 2>&1
perl -p -i -e 's/.* ...\s+\d{1,2}\s+\d{2}:\d{2} / /' out/dl_basic.out
diff out/dl_basic.out expected/dl_basic.out | grep -vE "........-....-....-....|^---|^[0-9,]+[a-f][0-9,]+"

init_test
echo "Running advanced tests..."
psql -f sql/dl_advanced.sql > out/dl_advanced.out 2>&1
perl -p -i -e 's/.* ...\s+\d{1,2}\s+\d{2}:\d{2} / /' out/dl_advanced.out
diff out/dl_advanced.out expected/dl_advanced.out | sed 's/... .. ..:..//' | grep -v " \.\.$" | grep -vE "........-....-....-....|^---|^[0-9,]+[a-f][0-9,]+|postgres postgres"

#rm -rf out/
#rm -rf /tmp/test_datalink/
#rm -f /tmp/img2.png

