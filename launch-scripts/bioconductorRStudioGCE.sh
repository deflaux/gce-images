#!/bin/sh
#
# Copyright 2015 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Starts a Bioconductor docker container deployed to a GCE VM.

HELP_INFO=

gcloud -q config list compute/zone --format text | grep -q -i -F "none"
if [ $? = 0 ]; then
  HELP_INFO="Default compute zone is not set.  To set it, run: gcloud config set compute/zone us-central1-a"
fi

gcloud -q config list project --format text | grep -q -i -F "none"
if [ $? = 0 ]; then
  HELP_INFO="Default cloud project is not set. To set it, run: gcloud config set project YOUR-PROJECT"
fi

if [ "$#" = "1" ] && [ "$1" = "--help" ]; then
  HELP_INFO="Bioconductor on Google Cloud Platform"
fi

if [ "$HELP_INFO" != "" ]; then
  echo $HELP_INFO
  echo
  echo "Usage: $0 [<vm name>] [<vm type>] [<version>]"
  echo "  vm name: the name of the VM to create (default: bioc)"
  echo "  vm type: the type of VM to create (default: n1-standard-2)"
  echo "  version: the docker container version to use (default: latest)"
  echo
  echo "Required configuration:"
  echo "  - default cloud project"
  echo "    gcloud config set project <project name>"
  echo "  - default compute zone"
  echo "    gcloud config set compute/zone <zone name>"
  echo "  - docker registry (while docker image is unavailable via docker.io)"
  echo "    export DOCKER_REGISTRY=<docker host:port>"
  echo

  exit 1
fi

# Initialize variables
if [ "$1" = "" ]; then
  VM=bioc-${USER}
else
  VM=$1
fi
if [ "$2" = "" ]; then
  VM_TYPE="n1-standard-2"
else
  VM_TYPE=$2
fi

VM_IMAGE=container-vm-v20150129
if [ "$3" = "" ]; then
  TAG=0.02
else
  TAG=$3
fi

VM_IMAGE=container-vm-v20150129
DOCKER_IMAGE="b.gcr.io/bioctest/devel_sequencing:$TAG"

CLOUD_PROJECT=`gcloud config list project --format text | sed 's/core\.project: //'`
NETWORK_NAME=bioc
LOCALPORT=8787
URL="http://localhost:$LOCALPORT"

echo "Starting Bioconductor on VM '$VM' ($VM_TYPE) ..."


# Check if port is already in use
lsof -i4tcp:$LOCALPORT >> /dev/null
if [ $? = 0 ]; then
  PID=`lsof -t -i4tcp:$LOCALPORT 2> /dev/null`
  ps $PID

  echo
  echo "Port $LOCALPORT is in use by process $PID. Kill the proccess and free it first."
  echo "Or browse to $URL (if the process is also an RStudio Server run)."

  exit 1
fi


# First create the network (if it doesn't already exist)
gcloud -q compute networks describe $NETWORK_NAME &> /dev/null
if [ $? -gt 0 ]; then
  echo "Creating network '$NETWORK_NAME' to associate with VM ..."

  gcloud -q compute networks create $NETWORK_NAME &> /dev/null
  if [ $? != 0 ]; then
    echo "Failed to create network '$NETWORK_NAME'"
    exit 1
  fi
fi

# Add a firewall rule to allow SSH (if it doesn't already exist)
gcloud -q compute firewall-rules describe allow-ssh-${NETWORK_NAME} &> /dev/null
if [ $? -gt 0 ]; then
  echo "Adding firewall rule to allow SSH access in network '$NETWORK_NAME' ..."

  gcloud -q compute firewall-rules create allow-ssh-${NETWORK_NAME} --allow tcp:22 \
    --network $NETWORK_NAME &> /dev/null
  if [ $? != 0 ]; then
    echo "Failed to create firewall rule to allow SSH in network '$NETWORK_NAME'"
    exit 1
  fi
fi

# Create VM instance (if it doesn't already exist)
gcloud -q compute instances describe $VM &> /dev/null
if [ $? -gt 0 ]; then
  # Generate the VM manifest
  cat > vm.yaml << EOF1
version: v1beta2
containers:
  - name: $VM
    image: $DOCKER_IMAGE
    env:
      - name: CLOUD_PROJECT
        value: $CLOUD_PROJECT
    ports:
      - name: bioc
        hostPort: 8787
        containerPort: 8787
    volumeMounts:
      - name: log
        mountPath: /var/log/bioc
volumes:
  - name: log
    source:
      hostDir:
        path: /bioc/log

EOF1

  # Create the VM
  echo "Creating VM instance '$VM' ..."
  gcloud -q compute instances create $VM \
    --image $VM_IMAGE \
    --image-project google-containers \
    --machine-type $VM_TYPE \
    --network $NETWORK_NAME \
    --boot-disk-size 50GB \
    --scopes=storage-full,bigquery,datastore,sql \
    --metadata-from-file google-container-manifest=vm.yaml \
    --tags "bioc"
  if [ $? != 0 ]; then
    rm vm.yaml

    echo "Failed to create VM instance named $VM"
    exit 1
  else
    rm vm.yaml
  fi
  echo
else
  echo "Using existing VM instance '$VM'"
fi

# Wait for VM to start
echo "Waiting for VM instance '$VM' to start ..."
until (gcloud -q compute instances describe $VM 2>/dev/null | grep -q '^status:[ \t]*RUNNING'); do
  sleep 2
  printf "."
done
printf "\n"


# Wait for Bioconductor to start and become accessible
echo "Waiting for the Bioconductor container to start ..."
until (gcloud -q compute ssh --command "sudo docker ps" $VM 2> /dev/null | grep -q ${DOCKER_IMAGE}); do
  sleep 2
  printf "."
done
printf "\n"


# Set up ssh tunnel to VM
echo "Creating SSH tunnel to VM instance '$VM' ..."
gcloud -q compute ssh --ssh-flag="-L $LOCALPORT:localhost:8787" --ssh-flag="-f" --ssh-flag="-N" $VM
if [ $? != 0 ]; then
  echo "Failed to create SSH tunnel to VM '$VM'"
  exit 1
fi


# Wait for RStudio Server to start and become accessible
echo "Waiting for RStudio Server to start ..."
until (curl -s -o /dev/null localhost:$LOCALPORT); do
  sleep 2
  printf "."
done
printf "\n"

echo "VM instance '$VM' is ready for use ..."


# Open RStudio in local browser session
echo "Browsing to $URL ..."
case $(uname) in
  'Darwin') open $URL ;;
  'Linux') x-www-browser $URL ;;
  *) echo "Please open a browser instance to $URL to get started."
    ;;
esac

exit 0
