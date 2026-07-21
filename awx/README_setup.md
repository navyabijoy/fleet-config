# AWX Bootstrap on EC2 t3.micro

Step-by-step setup for the AWX control node.

## 1. Launch EC2 Instance

- **AMI**: Ubuntu 22.04 LTS (us-east-1: `ami-0c7217cdde317cfec`)
- **Instance type**: t3.micro (2 GB RAM — minimum viable for AWX)
- **Security group**: Allow inbound TCP 22 (SSH), TCP 80 (AWX UI) from your IP only
- **Key pair**: Use your existing key pair or create `fleet_key.pem`
- **IAM instance profile**: Attach a role with `ec2:DescribeInstances` + `ec2:DescribeTags`
- **Storage**: 20 GB gp3 (AWX images + postgres data)

## 2. Install Docker

```bash
# SSH into the instance
ssh -i fleet_key.pem ubuntu@<EC2_PUBLIC_IP>

# Update and install Docker
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-plugin
sudo usermod -aG docker ubuntu

# Log out and back in for the group change to take effect
exit
ssh -i fleet_key.pem ubuntu@<EC2_PUBLIC_IP>
```

## 3. Configure Secrets

```bash
# Clone this repo
git clone https://github.com/<YOUR_ORG>/fleet-config.git
cd fleet-config/awx

# Create your .env from the template — never commit this file
cp .env.example .env
nano .env   # fill in SECRET_KEY, POSTGRES_PASSWORD, AWX_ADMIN_PASSWORD
```

Generate strong values:

```bash
# SECRET_KEY (64-char hex)
python3 -c "import secrets; print(secrets.token_hex(64))"

# Passwords (32-char URL-safe)
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

## 4. Deploy AWX

```bash
# Start the AWX stack (from the awx/ directory)
docker compose --env-file .env up -d

# Watch AWX initialise (~3 minutes)
docker compose logs -f awx_web | grep -E "AWX is ready|error"
```

## 5. Verify the Stack is Running

```bash
# All four containers must be Up
docker compose ps

# Check AWX web is responding
curl -s -o /dev/null -w "%{http_code}" http://localhost/api/v2/ping/
# Expected: 200
```

## 6. Changing AWX_ADMIN_PASSWORD

**Option A — Before first deploy** (preferred):
Edit `awx/.env` and change `AWX_ADMIN_PASSWORD` before running `docker compose up`.

**Option B — After deploy, via the AWX UI**:
1. Log in at `http://<EC2_PUBLIC_IP>` with the current password
2. Navigate to **Settings → Users → admin → Edit**
3. Set a new password and click **Save**

**Option C — After deploy, via the AWX CLI**:
```bash
export AWX_HOST=http://<EC2_PUBLIC_IP>
export AWX_USERNAME=admin
export AWX_PASSWORD=<current-password>

awx --conf.host "${AWX_HOST}" \
    --conf.username "${AWX_USERNAME}" \
    --conf.password "${AWX_PASSWORD}" \
    users modify 1 --password "<new-password>"
```

**Option D — Directly in the container**:
```bash
docker compose exec awx_web awx-manage update_password \
  --username admin \
  --password '<new-password>'
```

> **Note**: Options C and D do not require restarting the stack. The `.env` file is only read at container startup — changing it after deploy has no effect until you run `docker compose up -d` again.

## 7. Upload SSH Machine Credential

In the AWX UI:
1. **Credentials → Add**
2. Name: `fleet-ssh-key`
3. Credential type: **Machine**
4. SSH Private Key: paste contents of `fleet_key.pem`
5. Save

## 8. Run AWX Config-as-Code

```bash
# On your local machine (or the EC2 control node)
export AWX_HOST=http://<EC2_PUBLIC_IP>
export AWX_USERNAME=admin
export AWX_PASSWORD=<your-password>

pip install awxkit
bash awx/job_templates.sh
```

This creates all job templates, schedules, and the emergency patch survey.

## 9. Verify Ansible Connectivity

```bash
# Test dynamic inventory locally first
export AWS_DEFAULT_REGION=us-east-1
python3 inventory/aws_ec2.py --list | python3 -m json.tool
# Should show your tagged EC2 instances under the "staging" group
```

In AWX: **Inventories → fleet-staging → Sources → Sync** — verify hosts appear.

## Cost Estimate (Free Tier)

| Resource | Type | Monthly Cost |
|----------|------|-------------|
| AWX control node | t3.micro (750 hrs/mo free) | $0 |
| Target hosts × 2 | t2.micro (750 hrs/mo free) | $0 |
| Storage | 20 GB gp3 (30 GB/mo free) | $0 |
| Data transfer | Minimal intra-region | $0 |
| **Total** | | **$0** |

> Free tier includes 750 hours/month of t2.micro and t3.micro **combined**.
> Running 3 instances 24/7 = 2160 hours — exceeds free hours.
> **Recommendation**: Stop instances when not actively demoing to stay in free tier.
