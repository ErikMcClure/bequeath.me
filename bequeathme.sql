-- --------------------------------------------------------
-- Host:                         127.0.0.1
-- Server version:               10.2.11-MariaDB - mariadb.org binary distribution
-- Server OS:                    Win64
-- HeidiSQL Version:             9.4.0.5192
-- --------------------------------------------------------

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET NAMES utf8 */;
/*!50503 SET NAMES utf8mb4 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;


-- Dumping database structure for bequeathme
CREATE DATABASE IF NOT EXISTS `bequeathme` /*!40100 DEFAULT CHARACTER SET utf8mb4 */;
USE `bequeathme`;

-- Dumping structure for table bequeathme.activity
CREATE TABLE IF NOT EXISTS `activity` (
  `Day` tinyint(3) unsigned NOT NULL,
  `Hour` tinyint(3) unsigned NOT NULL,
  `Visits` bigint(20) unsigned NOT NULL,
  PRIMARY KEY (`Day`,`Hour`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='A helper table for the backend to store website activity that can be easily averaged to find the least active hour of any given week.';

-- Data exporting was unselected.
-- Dumping structure for procedure bequeathme.AddCharge
DELIMITER //
CREATE DEFINER=`root`@`localhost` PROCEDURE `AddCharge`(IN `_page` BIGINT UNSIGNED)
    MODIFIES SQL DATA
    COMMENT 'Creates a new charge and the associated transactions for all the pledges'
BEGIN

INSERT INTO charges (Page) VALUES (_page);
SET @charge = LAST_INSERT_ID();

CALL AddChargeTransactions(@charge, _page);

END//
DELIMITER ;

-- Dumping structure for procedure bequeathme.AddChargeTransactions
DELIMITER //
CREATE DEFINER=`root`@`localhost` PROCEDURE `AddChargeTransactions`(
	IN `_charge` BIGINT UNSIGNED,
	IN `_page` BIGINT UNSIGNED


)
    MODIFIES SQL DATA
BEGIN

DECLARE done INT DEFAULT FALSE;
DECLARE i BIGINT UNSIGNED;
DECLARE cur CURSOR FOR SELECT P.Source FROM pledges P INNER JOIN sources S ON S.ID = P.Source WHERE P.Page = _page AND P.Paused = 0 AND S.Trusted = 0;
DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

INSERT INTO transactions (`User`, Page, Charge, Reward, Source, Amount)
SELECT `User`, Page, _charge, Reward, Source, Amount
FROM pledges
WHERE Page = _page AND Paused = 0;

-- If any pledgers have failed transactions and an untrusted valid payment source, force processing
OPEN cur;

read_loop: LOOP
 FETCH cur INTO i;
 IF done THEN
   LEAVE read_loop;
 END IF;
 CALL ValidateSource(i); -- Note: It's fine if a race condition results in attempting to validate a pledge that was not actually charged.
END LOOP;

CLOSE cur;

END//
DELIMITER ;

-- Dumping structure for procedure bequeathme.AddComment
DELIMITER //
CREATE DEFINER=`root`@`localhost` PROCEDURE `AddComment`(IN `_user` BIGINT UNSIGNED, IN `_post` BIGINT UNSIGNED, IN `_reply` BIGINT UNSIGNED, IN `_content` VARCHAR(2048))
    COMMENT 'Adds a comment and sends out notifications'
BEGIN

INSERT INTO comments (`User`, Post, Reply, Content)
VALUES (_user, _post, _reply, _content);

SET @id = LAST_INSERT_ID();
SET @author = (SELECT `User` FROM posts WHERE ID = _post);
IF _reply IS NOT NULL THEN
	SET @other = (SELECT `User` FROM comments WHERE ID = _reply);
	
	INSERT INTO notifications (`User`, `Post`, `Type`, `Data`, `Aux`)
	VALUES (@other, _post, 2, @id, _reply);
	
	IF @other != _user THEN
		INSERT INTO notifications (`User`, `Post`, `Type`, `Data`)
		VALUES (@author, _post, 1, @id);
	END IF;
ELSE
	INSERT INTO notifications (`User`, `Post`, `Type`, `Data`)
	VALUES (@author, _post, 1, @id);
END IF;

END//
DELIMITER ;

-- Dumping structure for procedure bequeathme.AddPledge
DELIMITER //
CREATE DEFINER=`root`@`localhost` PROCEDURE `AddPledge`(
	IN `_user` BIGINT UNSIGNED,
	IN `_page` BIGINT UNSIGNED,
	IN `_source` BIGINT UNSIGNED,
	IN `_amount` DECIMAL(10,8) UNSIGNED,
	IN `_reward` BIGINT UNSIGNED,
	IN `_notify` TINYINT UNSIGNED



)
    DETERMINISTIC
    COMMENT 'Adds or updates a pledge, updating transactions as necessary'
BEGIN

DECLARE author BIGINT UNSIGNED;
DECLARE monthly BIT;
SELECT `User`, Monthly INTO author, monthly FROM pages WHERE ID = _page;

SET @notify = 3; -- pledge added
IF EXISTS (SELECT ID FROM pledges WHERE `User` = _user AND Page = _page FOR UPDATE) THEN -- Use FOR UPDATE to prevent deadlock scenario due to potential update below
	SET @notify = 4; -- pledge edited
END IF;

INSERT INTO notifications (`User`, `Page`, `Type`, `Data`)
VALUES (author, _page, @notify, _user);

INSERT INTO pledges (`User`, Page, Source, Amount, Reward, Notify)
VALUES (_user, _page, _source, _amount, _reward, _notify)
ON DUPLICATE KEY UPDATE Source = _source, Amount = _amount, Reward = _reward, Notify = _notify;

IF monthly = 1 THEN
	-- Check if there is an existing monthly transaction in the current month (non-monthly transactions could exist if the page was changed). Exclude NULL charges with negative amounts because those are refunds.
	SELECT @existing := ID, @amount := Amount FROM currentmonth WHERE `User` = _user AND Page = _page AND Charge IS NULL AND Amount >= 0;
	
	IF @existing IS NOT NULL THEN
		IF _amount > @amount THEN -- Only if you raised your pledge do we update the transaction
			UPDATE transactions SET Amount = _amount WHERE ID = @existing AND `Process` IS NULL;
		END IF;
	ELSE  -- Otherwise insert a new one
		INSERT INTO transactions (`User`, Page, Source, Amount, Reward)
		VALUES (_user, _page, _source, _amount, _reward);
	END IF;
END IF;

END//
DELIMITER ;

-- Dumping structure for procedure bequeathme.AddSourceStripe
DELIMITER //
CREATE DEFINER=`root`@`localhost` PROCEDURE `AddSourceStripe`(
	IN `_user` BIGINT UNSIGNED,
	IN `_stripe` VARCHAR(48)


)
    DETERMINISTIC
    COMMENT 'Adds a stripe payment source'
BEGIN

INSERT INTO sources (`User`, Stripe)
VALUES (_user, _stripe);
CALL FixTransactions(_user);
CALL ValidateSource(LAST_INSERT_ID());

END//
DELIMITER ;

-- Dumping structure for table bequeathme.alerts
CREATE TABLE IF NOT EXISTS `alerts` (
  `ID` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `Type` smallint(5) unsigned NOT NULL DEFAULT 0,
  `Data` bigint(20) unsigned NOT NULL DEFAULT 0,
  `Timestamp` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='These are developer alerts that are e-mailed to a response team. The backend has the option of dealing with different alert types in different ways.';

-- Data exporting was unselected.
-- Dumping structure for procedure bequeathme.BanUser
DELIMITER //
CREATE DEFINER=`root`@`localhost` PROCEDURE `BanUser`(
	IN `_user` BIGINT UNSIGNED
)
    MODIFIES SQL DATA
    DETERMINISTIC
    COMMENT 'Bans a user, deleting all pledges and pages. Does not delete source methods or pending transactions, but the backend should attempt to force source of pending transactions anyway.'
BEGIN

UPDATE users SET Banned = 1 WHERE `User` = _user;
DELETE FROM notifications WHERE `User` = _user;

DELETE FROM pledges WHERE `User` = OLD.ID;
UPDATE pages SET Suspended = 1 WHERE `User` = OLD.ID;

END//
DELIMITER ;

-- Dumping structure for table bequeathme.blocked
CREATE TABLE IF NOT EXISTS `blocked` (
  `User` bigint(20) unsigned NOT NULL COMMENT 'User doing the blocking',
  `Blocked` bigint(20) unsigned NOT NULL COMMENT 'User that was blocked',
  `Timestamp` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`User`,`Blocked`),
  KEY `FK_BLOCKED_USERS2` (`Blocked`),
  CONSTRAINT `FK_BLOCKED_USERS` FOREIGN KEY (`User`) REFERENCES `users` (`ID`),
  CONSTRAINT `FK_BLOCKED_USERS2` FOREIGN KEY (`Blocked`) REFERENCES `users` (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Tracks which users have been blocked by another user.';

-- Data exporting was unselected.
-- Dumping structure for procedure bequeathme.CalculatePayments
DELIMITER //
CREATE DEFINER=`root`@`localhost` PROCEDURE `CalculatePayments`(
	IN `_time` DATE
)
    COMMENT 'Calculates the payments necessary for all transactions scheduled in the given month'
BEGIN
	
DECLARE done INT DEFAULT FALSE;
DECLARE source BIGINT UNSIGNED;
DECLARE cur CURSOR FOR SELECT DISTINCT Source FROM TRANSACTIONS_TEMP;
DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

-- Coalesce all transactions this month that have either failed or don't have a payment yet into payments based on sources
CREATE TEMPORARY TABLE TRANSACTIONS_TEMP ( 
	ID BIGINT UNSIGNED,
	Source BIGINT UNSIGNED,
	Amount DECIMAL(10,8)
	) ENGINE=MEMORY;

INSERT INTO TRANSACTIONS_TEMP
SELECT T.ID, T.Source, T.Amount
FROM transactions T INNER JOIN sources S ON T.Source = S.ID
WHERE T.`User` = @author AND S.Invalid = 0 AND T.`Timestamp` <= _time AND (T.Failed = 1 OR T.Payment IS NULL)
  AND T.`Timestamp` >= UNIX_TIMESTAMP(LAST_DAY(_time) + INTERVAL 1 DAY - INTERVAL 1 MONTH)
  AND T.`Timestamp` <  UNIX_TIMESTAMP(LAST_DAY(_time) + INTERVAL 1 DAY) FOR UPDATE;
  
OPEN cur;

read_loop: LOOP
	FETCH cur INTO source;
	IF done THEN
		LEAVE read_loop;
	END IF;

	INSERT INTO payments (Source, Amount)
	SELECT Source, SUM(Amount)
	FROM TRANSACTIONS_TEMP
	WHERE Source = source
	GROUP BY Source;
	
	UPDATE transactions
	SET Payment = LAST_INSERT_ID()
	WHERE ID IN (SELECT ID FROM TRANSACTIONS_TEMP WHERE Source = source);	
END LOOP;

CLOSE cur;



END//
DELIMITER ;

-- Dumping structure for procedure bequeathme.CalculatePayouts
DELIMITER //
CREATE DEFINER=`root`@`localhost` PROCEDURE `CalculatePayouts`(
	IN `_buffer` DECIMAL(10,8),
	IN `_targetbuffer` DECIMAL(10,8),
	IN `_bufferpercent` FLOAT,
	IN `_maxpercent` FLOAT





)
    COMMENT 'Incorporates expenses and calculates total payout for all creators. Must be called after all backer transactions have been processed, so failed pledges can be taken into account.'
BEGIN

-- Set the ingesting flag on these payments. We can query this value to check if this function has failed and needs to be called again.
UPDATE payments SET Ingesting = 1 WHERE Processing IS NULL AND Failed = 0 AND Fee IS NOT NULL;
SELECT @income := SUM(Amount), @fees := SUM(Fee) FROM payments WHERE Ingesting = 1 FOR UPDATE;

-- Set the ingesting flag on the expenses and query them as well.
UPDATE expenses SET Ingesting = 1 WHERE `Timestamp` <= _time AND Paid = 0;
SELECT @expense := SUM(Amount) FROM expenses WHERE Ingesting = 1 FOR UPDATE;

-- If we go over the buffer payout % we want, we'll use up to half the buffer to try and cover the difference before raising the percent take again.

-- If we go above the maximum payout %, we can't cover all expenses, so we pay as many as we can in full, starting from the largest.


-- Success, update payments signifying that they have been successfully processed
UPDATE payments SET Ingesting = 0, Processing = CURRENT_TIMESTAMP() WHERE Ingesting = 1;
UPDATE expenses SET Ingesting = 0 WHERE Ingesting = 1;

END//
DELIMITER ;

-- Dumping structure for table bequeathme.charges
CREATE TABLE IF NOT EXISTS `charges` (
  `ID` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `Page` bigint(20) unsigned NOT NULL,
  `Timestamp` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`ID`),
  KEY `FK_CHARGES_PAGES` (`Page`),
  CONSTRAINT `FK_CHARGES_PAGES` FOREIGN KEY (`Page`) REFERENCES `pages` (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Data exporting was unselected.
-- Dumping structure for event bequeathme.Coalesce
DELIMITER //
CREATE DEFINER=`root`@`localhost` EVENT `Coalesce` ON SCHEDULE EVERY 1 MONTH STARTS '2017-12-02 00:01:01' ON COMPLETION PRESERVE ENABLE COMMENT 'Creates processing rows for last month' DO BEGIN

CALL CalculatePayments(DATE_SUB(CURDATE(), INTERVAL 4 DAY));
CALL GenMonthlyTransactions(CURDATE());

END//
DELIMITER ;

-- Dumping structure for table bequeathme.comments
CREATE TABLE IF NOT EXISTS `comments` (
  `ID` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `User` bigint(20) unsigned NOT NULL,
  `Post` bigint(20) unsigned NOT NULL,
  `Reply` bigint(20) unsigned DEFAULT NULL,
  `Timestamp` timestamp NOT NULL DEFAULT current_timestamp(),
  `Edited` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `Content` varchar(2048) NOT NULL,
  PRIMARY KEY (`ID`),
  KEY `INDEX_USER` (`User`),
  KEY `INDEX_POST` (`Post`),
  KEY `FK_COMMENTS_COMMENTS` (`Reply`),
  CONSTRAINT `FK_COMMENTS_COMMENTS` FOREIGN KEY (`Reply`) REFERENCES `comments` (`ID`),
  CONSTRAINT `FK_COMMENTS_POSTS` FOREIGN KEY (`Post`) REFERENCES `posts` (`ID`),
  CONSTRAINT `FK_COMMENTS_USERS` FOREIGN KEY (`User`) REFERENCES `users` (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Data exporting was unselected.
-- Dumping structure for view bequeathme.currentmonth
-- Creating temporary table to overcome VIEW dependency errors
CREATE TABLE `currentmonth` 
) ENGINE=MyISAM;

-- Dumping structure for procedure bequeathme.EditMessage
DELIMITER //
CREATE DEFINER=`root`@`localhost` PROCEDURE `EditMessage`(
	IN `_id` BIGINT UNSIGNED,
	IN `_recipient` BIGINT UNSIGNED,
	IN `_title` VARCHAR(256),
	IN `_content` TEXT
)
    COMMENT 'Edits a message, but only if it hasn''t been sent yet.'
BEGIN

IF (SELECT Draft FROM messages WHERE ID = _id FOR UPDATE) = 0 THEN
	UPDATE messages SET Recipient = _recipient, Title = _title, Content = _content WHERE ID = _id;
END IF;

END//
DELIMITER ;

-- Dumping structure for procedure bequeathme.EditReward
DELIMITER //
CREATE DEFINER=`root`@`localhost` PROCEDURE `EditReward`(
	IN `_reward` BIGINT UNSIGNED,
	IN `_order` TINYINT,
	IN `_name` VARCHAR(256),
	IN `_description` VARCHAR(1024),
	IN `_amount` DECIMAL(10,8)





)
    COMMENT 'Edits a reward, updating backer rewards based on pledge amount.'
BEGIN


DECLARE done INT DEFAULT FALSE;
DECLARE u BIGINT UNSIGNED;
DECLARE p BIGINT UNSIGNED;
DECLARE a DECIMAL(10,8);
DECLARE cur CURSOR FOR SELECT P.`User`, P.Page, P.Amount FROM pledges P INNER JOIN rewards R ON P.Reward = R.ID WHERE P.Amount < R.Amount FOR UPDATE;
DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

UPDATE rewards 
SET `Order` = _order, Name = _name, Description = _description, Amount = _amount 
WHERE ID = _reward;

-- After updating the reward, go through all pledges and look for ones that no longer qualify for their reward  
OPEN cur;

read_loop: LOOP
	FETCH cur INTO u, p, a;
	IF done THEN
		LEAVE read_loop;
	END IF;

	UPDATE pledges 
	SET Reward = (SELECT ID FROM rewards WHERE Page = p AND Amount <= a ORDER BY Amount DESC, `Order` ASC LIMIT 1)
	WHERE `User` = u AND Page = p;
	
	-- TODO: consider updating transactions as well
END LOOP;

CLOSE cur;

END//
DELIMITER ;

-- Dumping structure for table bequeathme.expenses
CREATE TABLE IF NOT EXISTS `expenses` (
  `ID` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `Amount` decimal(10,8) NOT NULL,
  `Timestamp` timestamp NOT NULL DEFAULT current_timestamp(),
  `Paid` bit(1) NOT NULL DEFAULT b'0',
  `Ingesting` bit(1) NOT NULL DEFAULT b'0',
  `Priority` int(11) NOT NULL DEFAULT 0,
  `Category` tinyint(3) unsigned NOT NULL DEFAULT 0,
  PRIMARY KEY (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Expenses calculated by the backend that will need to be paid at the end of the month. Any expenses that are not accounted for carry over for next month. The backend can use a buffer zone to smooth over expenses.';

-- Data exporting was unselected.
-- Dumping structure for procedure bequeathme.FixTransactions
DELIMITER //
CREATE DEFINER=`root`@`localhost` PROCEDURE `FixTransactions`(
	IN `_user` BIGINT UNSIGNED
)
    MODIFIES SQL DATA
    COMMENT 'If a valid source method exists, assigns it to any transactions that don''t currently have one.'
UPDATE transactions
SET Source = (SELECT Source FROM sources WHERE `User` = _user AND Invalid = 0 LIMIT 1)
WHERE `User` = _user AND Source IS NULL AND (Failed = 1 OR Payment IS NULL)//
DELIMITER ;

-- Dumping structure for table bequeathme.flags
CREATE TABLE IF NOT EXISTS `flags` (
  `User` bigint(20) unsigned NOT NULL,
  `Data` bigint(20) unsigned NOT NULL,
  `Type` tinyint(3) unsigned NOT NULL COMMENT '0: page, 1: post, 2: comment',
  `Timestamp` timestamp NOT NULL DEFAULT current_timestamp(),
  `Confirmed` bit(1) DEFAULT NULL,
  PRIMARY KEY (`User`,`Data`,`Type`),
  CONSTRAINT `FK_FLAGS_USERS` FOREIGN KEY (`User`) REFERENCES `users` (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='This tracks who has flagged a page, post, or comment and at what time.';

-- Data exporting was unselected.
-- Dumping structure for procedure bequeathme.GenMonthlyTransactions
DELIMITER //
CREATE DEFINER=`root`@`localhost` PROCEDURE `GenMonthlyTransactions`(
	IN `_date` DATE



)
    MODIFIES SQL DATA
    COMMENT 'Generates transactions for the given month, but only if those transactions don''t already exist.'
BEGIN

SET @firstday = UNIX_TIMESTAMP(LAST_DAY(_date) + INTERVAL 1 DAY - INTERVAL 1 MONTH);

IF (SELECT COUNT(*) FROM transactions WHERE Charge IS NULL AND Amount >= 0 
	AND `Timestamp` >= @firstday
	AND `Timestamp` <  UNIX_TIMESTAMP(LAST_DAY(_date) + INTERVAL 1 DAY)) = 0 THEN
	
	INSERT INTO transactions (`User`, Page, Reward, Source, Amount, `Timestamp`)
	SELECT B.`User`, B.Page, B.Reward, B.Source, B.Amount, @firstday
	FROM pledges B INNER JOIN pages P ON B.Page = P.ID
	WHERE P.Monthly = 1 AND P.Draft = 0 AND B.Paused = 0;
END IF;

END//
DELIMITER ;

-- Dumping structure for table bequeathme.goals
CREATE TABLE IF NOT EXISTS `goals` (
  `Page` bigint(20) unsigned NOT NULL,
  `Amount` decimal(10,8) unsigned NOT NULL,
  `Name` varchar(128) NOT NULL,
  `Description` varchar(2048) NOT NULL,
  PRIMARY KEY (`Page`,`Amount`),
  CONSTRAINT `FK_GOALS_PAGES` FOREIGN KEY (`Page`) REFERENCES `pages` (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Data exporting was unselected.
-- Dumping structure for table bequeathme.messages
CREATE TABLE IF NOT EXISTS `messages` (
  `ID` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `Sender` bigint(20) unsigned DEFAULT NULL,
  `Recipient` bigint(20) unsigned DEFAULT NULL,
  `Title` varchar(256) NOT NULL,
  `Content` text NOT NULL,
  `Timestamp` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `Draft` bit(1) NOT NULL DEFAULT b'1',
  PRIMARY KEY (`ID`),
  KEY `FK_MESSAGES_USERS` (`Sender`),
  KEY `FK_MESSAGES_USERS2` (`Recipient`),
  CONSTRAINT `FK_MESSAGES_USERS` FOREIGN KEY (`Sender`) REFERENCES `users` (`ID`),
  CONSTRAINT `FK_MESSAGES_USERS2` FOREIGN KEY (`Recipient`) REFERENCES `users` (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Direct messages from creators to backers';

-- Data exporting was unselected.
-- Dumping structure for table bequeathme.notifications
CREATE TABLE IF NOT EXISTS `notifications` (
  `ID` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `User` bigint(20) unsigned NOT NULL,
  `Page` bigint(20) unsigned DEFAULT NULL,
  `Post` bigint(20) unsigned DEFAULT NULL,
  `Timestamp` timestamp NOT NULL DEFAULT current_timestamp(),
  `Type` smallint(5) unsigned NOT NULL COMMENT '1 comment on post, 2 reply to comment, 3 pledge added, 4 pledge edited, 5 pledge removed, 6 page deleted, 7 user deleted, 8 post added, 9 payment succeeded, 10 payment failed, 11 payment refunded, 12 payout succeeded, 13 payout failed',
  `Data` bigint(20) unsigned NOT NULL,
  `Aux` bigint(20) unsigned NOT NULL DEFAULT 0,
  PRIMARY KEY (`ID`),
  KEY `FK_NOTIFICATIONS_USERS` (`User`),
  KEY `FK_NOTIFICATIONS_PAGES` (`Page`),
  KEY `FK_NOTIFICATIONS_POSTS` (`Post`),
  CONSTRAINT `FK_NOTIFICATIONS_PAGES` FOREIGN KEY (`Page`) REFERENCES `pages` (`ID`),
  CONSTRAINT `FK_NOTIFICATIONS_POSTS` FOREIGN KEY (`Post`) REFERENCES `posts` (`ID`),
  CONSTRAINT `FK_NOTIFICATIONS_USERS` FOREIGN KEY (`User`) REFERENCES `users` (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Data exporting was unselected.
-- Dumping structure for table bequeathme.oauth
CREATE TABLE IF NOT EXISTS `oauth` (
  `User` bigint(20) unsigned NOT NULL,
  `Service` smallint(5) unsigned NOT NULL,
  `AccessToken` varchar(64) NOT NULL,
  `RefreshToken` varchar(64) NOT NULL,
  `Expires` datetime DEFAULT NULL,
  `Scope` bigint(20) unsigned NOT NULL DEFAULT 0,
  PRIMARY KEY (`User`,`Service`),
  CONSTRAINT `FK_OAUTH_USERS` FOREIGN KEY (`User`) REFERENCES `users` (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Data exporting was unselected.
-- Dumping structure for table bequeathme.pages
CREATE TABLE IF NOT EXISTS `pages` (
  `ID` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `User` bigint(20) unsigned NOT NULL,
  `Monthly` bit(1) NOT NULL DEFAULT b'1',
  `Restricted` bit(1) NOT NULL DEFAULT b'0' COMMENT 'If true, only patrons that have paid for at least a month are allowed to comment',
  `Sensitive` bit(1) NOT NULL DEFAULT b'0',
  `Draft` bit(1) NOT NULL DEFAULT b'1',
  `Suspended` bit(1) NOT NULL DEFAULT b'0',
  `Name` varchar(256) NOT NULL,
  `Description` text NOT NULL,
  `Video` varchar(256) NOT NULL DEFAULT '''''',
  `Item` varchar(64) NOT NULL,
  `Background` varchar(256) NOT NULL DEFAULT '''''',
  `Edited` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`ID`),
  KEY `INDEX_USER` (`User`),
  CONSTRAINT `FK_PAGES_USERS` FOREIGN KEY (`User`) REFERENCES `users` (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Data exporting was unselected.
-- Dumping structure for table bequeathme.payments
CREATE TABLE IF NOT EXISTS `payments` (
  `ID` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `Source` bigint(20) unsigned DEFAULT NULL COMMENT 'This is only NULL if the source used to pay this was deleted',
  `Amount` decimal(10,8) NOT NULL,
  `Fee` decimal(10,8) DEFAULT NULL,
  `Failed` bit(1) NOT NULL DEFAULT b'0',
  `Refunded` bit(1) NOT NULL DEFAULT b'0' COMMENT 'Only used to deal with chargebacks',
  `Ingesting` bit(1) NOT NULL COMMENT 'Set to 1 while being processed. If processing fails, will mark the group of payments that need to be re-done',
  `Scheduled` timestamp NOT NULL DEFAULT current_timestamp(),
  `Processed` timestamp NULL DEFAULT NULL,
  `Confirmation` varchar(64) NOT NULL DEFAULT '''''',
  PRIMARY KEY (`ID`),
  KEY `FK_PROCESSING_SOURCES` (`Source`),
  CONSTRAINT `FK_PROCESSING_SOURCES` FOREIGN KEY (`Source`) REFERENCES `sources` (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Stores the actual, coalesced transaction payments going through source processors, whether it failed, the confirmation ID, when it was scheduled and when it was attempted. The backend queries this table for pending payments that need to be processed.';

-- Data exporting was unselected.
-- Dumping structure for table bequeathme.payouts
CREATE TABLE IF NOT EXISTS `payouts` (
  `ID` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `User` bigint(20) unsigned DEFAULT NULL COMMENT 'This is only NULL if the user was deleted',
  `Amount` decimal(10,8) NOT NULL,
  `Fee` decimal(10,8) DEFAULT NULL,
  `Paid` bit(1) NOT NULL DEFAULT b'0',
  `Timestamp` datetime NOT NULL DEFAULT current_timestamp(),
  `Confirmation` varchar(64) DEFAULT NULL,
  PRIMARY KEY (`ID`),
  KEY `FK_PAYOUTS_USERS` (`User`),
  CONSTRAINT `FK_PAYOUTS_USERS` FOREIGN KEY (`User`) REFERENCES `users` (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Tracks the sources that should be made to the creators, with expenses removed, adjusted to compensate for expected fees.';

-- Data exporting was unselected.
-- Dumping structure for table bequeathme.pledges
CREATE TABLE IF NOT EXISTS `pledges` (
  `User` bigint(20) unsigned NOT NULL,
  `Page` bigint(20) unsigned NOT NULL,
  `Source` bigint(20) unsigned NOT NULL,
  `Amount` decimal(10,8) unsigned NOT NULL,
  `Reward` bigint(20) unsigned NOT NULL,
  `Timestamp` timestamp NOT NULL DEFAULT current_timestamp(),
  `Edited` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `Paused` bit(1) NOT NULL DEFAULT b'0',
  `Notify` tinyint(3) unsigned NOT NULL DEFAULT 0 COMMENT 'Bit 1+2: notify on public posts, Bit 3+4: Notify on locked posts',
  PRIMARY KEY (`User`,`Page`),
  KEY `INDEX_REWARD` (`Reward`),
  KEY `FK_PLEDGES_PAGES` (`Page`),
  KEY `FK_PLEDGES_SOURCES` (`Source`),
  CONSTRAINT `FK_PLEDGES_PAGES` FOREIGN KEY (`Page`) REFERENCES `pages` (`ID`),
  CONSTRAINT `FK_PLEDGES_REWARDS` FOREIGN KEY (`Reward`) REFERENCES `rewards` (`ID`),
  CONSTRAINT `FK_PLEDGES_SOURCES` FOREIGN KEY (`Source`) REFERENCES `sources` (`ID`),
  CONSTRAINT `FK_PLEDGES_USERS` FOREIGN KEY (`User`) REFERENCES `users` (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Data exporting was unselected.
-- Dumping structure for table bequeathme.posts
CREATE TABLE IF NOT EXISTS `posts` (
  `ID` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `Page` bigint(20) unsigned NOT NULL,
  `Title` varchar(256) NOT NULL,
  `Content` text NOT NULL,
  `Timestamp` timestamp NOT NULL DEFAULT current_timestamp(),
  `Edited` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `Scheduled` timestamp NULL DEFAULT NULL COMMENT 'If not-null, this post will have Draft set to 0 at the specified time. ',
  `Charge` bigint(20) unsigned DEFAULT NULL,
  `Locked` bigint(20) unsigned DEFAULT NULL,
  `Draft` bit(1) NOT NULL DEFAULT b'1',
  `CreateCharge` bit(1) NOT NULL DEFAULT b'0' COMMENT 'If true a charge will be created when this post is published, but only if Charge is actually NULL',
  `Sensitive` bit(1) NOT NULL DEFAULT b'0',
  `DMCA` bit(1) NOT NULL DEFAULT b'0' COMMENT 'If true, taken down by DMCA',
  PRIMARY KEY (`ID`),
  KEY `INDEX_PAGE` (`Page`),
  KEY `FK_POSTS_REWARDS` (`Locked`),
  KEY `FK_POSTS_CHARGES` (`Charge`),
  CONSTRAINT `FK_POSTS_CHARGES` FOREIGN KEY (`Charge`) REFERENCES `charges` (`ID`),
  CONSTRAINT `FK_POSTS_PAGES` FOREIGN KEY (`Page`) REFERENCES `pages` (`ID`),
  CONSTRAINT `FK_POSTS_REWARDS` FOREIGN KEY (`Locked`) REFERENCES `rewards` (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Data exporting was unselected.
-- Dumping structure for procedure bequeathme.ProcessPayment
DELIMITER //
CREATE DEFINER=`root`@`localhost` PROCEDURE `ProcessPayment`(
	IN `_payment` BIGINT UNSIGNED,
	IN `_fee` DECIMAL(10,8),
	IN `_confirmation` VARCHAR(64)







)
    COMMENT 'Marks a payment as succeeded or failed. If it fails, marks the source as invalid.'
BEGIN

DECLARE u BIGINT UNSIGNED;
DECLARE source BIGINT UNSIGNED;
DECLARE amt DECIMAL(10,8);

SET @notify = 9;
SET @failed = 0;
IF _fee IS NULL THEN
	SET @failed = 1;
	SET @notify = 10;
END IF;

UPDATE payments
SET Failed = @failed, Fee = _fee, Confirmation = _confirmation
WHERE ID = _payment;

SELECT `User`, ID, Amount INTO u, source, amt
FROM payments 
WHERE ID = _payment FOR UPDATE;

IF _failed = 1 THEN
	UPDATE sources
	SET Invalid = 1, Trusted = 0 
	WHERE ID = source;
	
	SET @alt = (SELECT ID FROM sources WHERE `User` = u AND Invalid = 0 LIMIT 1);
	IF @alt IS NOT NULL THEN
		INSERT INTO payments (Source, Amount)
		VALUES (@alt, amt);		
	ELSE -- Otherwise there are no valid sources to fall back to, so mark all associated transactions as failed
		UPDATE transactions
		SET Failed = 1
		WHERE Payment = _payment;
	END IF;
END IF;


INSERT INTO notifications (`User`, `Type`, `Data`)
VALUES (u, @notify, _payment);
	
END//
DELIMITER ;

-- Dumping structure for procedure bequeathme.ProcessPayout
DELIMITER //
CREATE DEFINER=`root`@`localhost` PROCEDURE `ProcessPayout`(
	IN `_payout` BIGINT UNSIGNED,
	IN `_fee` DECIMAL(10,8),
	IN `_confirmation` VARCHAR(64)



)
    MODIFIES SQL DATA
    COMMENT 'Marks a payout as having succeeded or failed.'
BEGIN

SET @notify = 12;
SET @paid = 1;
IF _fee IS NULL THEN
	SET @paid = 0;
	SET @notify = 13;
END IF;

UPDATE payouts
SET Paid = @paid, Fee = _fee, Confirmation = _confirmation 
WHERE ID = _payout;

SET @u = (SELECT `User` FROM payouts WHERE ID = _payout);

IF _paid = 0 THEN
	UPDATE users
	SET PayoutFailure = 1
	WHERE ID = @u;
END IF;

INSERT INTO notifications (`User`, `Type`, `Data`)
VALUES (@u, @notify, _payout);

END//
DELIMITER ;

-- Dumping structure for procedure bequeathme.PublishPost
DELIMITER //
CREATE DEFINER=`root`@`localhost` PROCEDURE `PublishPost`(
	IN `_post` BIGINT UNSIGNED
)
    MODIFIES SQL DATA
    COMMENT 'Publishes a post, setting the Draft value to 0, creating a charge if necessary and notifying backers'
BEGIN

SELECT @draft := Draft, @charge := Charge, @locked := Locked, @createcharge := CreateCharge, @page := Page
FROM posts WHERE ID = _post FOR UPDATE; -- Must use FOR UPDATE here to obtain write lock

-- Do a sanity check here so we don't republish something multiple times due to race conditions
IF @draft = 1 THEN
	-- Only create a new charge if the current post has no charge
	IF @createcharge = 1 AND @charge IS NULL THEN
		INSERT INTO charges (Page) VALUES (@page);
		SET @charge = LAST_INSERT_ID();
		SET @createcharge = 0;
		
		CALL AddChargeTransactions(@charge, @page);
	END IF;
	
	UPDATE posts SET Draft = 0, Charge = @charge, CreateCharge = @createcharge, Scheduled = NULL WHERE ID = _post;
	
	INSERT INTO notifications (`User`, `Page`, `Post`, `Type`, `Data`)
	SELECT `User`, @page, @post, 8, 0
	FROM pledges
	WHERE Page = @page;
END IF;

END//
DELIMITER ;

-- Dumping structure for event bequeathme.PublishScheduledPosts
DELIMITER //
CREATE DEFINER=`root`@`localhost` EVENT `PublishScheduledPosts` ON SCHEDULE EVERY 15 MINUTE STARTS '2017-12-10 23:51:13' ON COMPLETION PRESERVE ENABLE COMMENT 'Publishes any scheduled posts' DO BEGIN

DECLARE done INT DEFAULT FALSE;
DECLARE i BIGINT UNSIGNED;
DECLARE cur CURSOR FOR SELECT ID FROM posts WHERE Draft = 1 AND Scheduled IS NOT NULL AND Scheduled <= CURRENT_TIMESTAMP();
DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;
  
OPEN cur;

read_loop: LOOP
 FETCH cur INTO i;
 IF done THEN
   LEAVE read_loop;
 END IF;
 CALL PublishPost(i);
END LOOP;

CLOSE cur;

END//
DELIMITER ;

-- Dumping structure for procedure bequeathme.RefundPayment
DELIMITER //
CREATE DEFINER=`root`@`localhost` PROCEDURE `RefundPayment`(
	IN `_payment` BIGINT UNSIGNED

)
    DETERMINISTIC
    COMMENT 'Refunding a payment marks it as refunded and deletes the associated transactions (since they effectively no longer exist)'
BEGIN

UPDATE payments
SET Refunded = 1
WHERE ID = _payment;

DELETE FROM transactions
WHERE Payment = _payment;

SET @u = (SELECT `User` FROM sources WHERE ID = (SELECT Source FROM payments WHERE ID = _payment));

IF @u IS NOT NULL THEN 
	INSERT INTO notifications (`User`, `Type`, `Data`)
	VALUES (@u, 11, _payout);
END IF;

END//
DELIMITER ;

-- Dumping structure for procedure bequeathme.RemoveCharge
DELIMITER //
CREATE DEFINER=`root`@`localhost` PROCEDURE `RemoveCharge`(IN `_charge` BIGINT UNSIGNED)
    MODIFIES SQL DATA
    DETERMINISTIC
    COMMENT 'This function removes a charge AND all of its associated posts.'
BEGIN

DELETE FROM posts WHERE Charge = _charge;
DELETE FROM charges WHERE ID = _charge;

END//
DELIMITER ;

-- Dumping structure for procedure bequeathme.RemoveComment
DELIMITER //
CREATE DEFINER=`root`@`localhost` PROCEDURE `RemoveComment`(IN `_comment` BIGINT UNSIGNED)
    MODIFIES SQL DATA
    DETERMINISTIC
    COMMENT 'Removes a comment by setting the content to an empty string, relying on the front end to replace this with [deleted]'
BEGIN

UPDATE comments SET Content = '' WHERE ID = _comment;
DELETE FROM notifications WHERE `Type` = 1 AND `Data` = _comment;

END//
DELIMITER ;

-- Dumping structure for procedure bequeathme.RemoveMessage
DELIMITER //
CREATE DEFINER=`root`@`localhost` PROCEDURE `RemoveMessage`(
	IN `_user` BIGINT UNSIGNED,
	IN `_message` BIGINT UNSIGNED

)
    COMMENT 'Deletes a message entirely if it hasn''t been sent, or removes a user from it.'
BEGIN

DECLARE sender BIGINT UNSIGNED;
DECLARE recipient BIGINT UNSIGNED;
DECLARE draft BIT;
SELECT Sender, Recipient, Draft INTO sender, recipient, draft FROM messages WHERE ID = _message FOR UPDATE;

IF draft = 1 AND sender = _user THEN
	DELETE FROM messages WHERE ID = _message;
ELSEIF draft = 0 AND sender = _user THEN
	UPDATE messages SET Sender = NULL WHERE ID = _message;
ELSEIF draft = 0 AND recipient = _user THEN
	UPDATE messages SET Recipient = NULL WHERE ID = _message;
ELSE
	SIGNAL SQLSTATE '45000'
	SET MESSAGE_TEXT = 'Can\'t delete message a user isn\'t actually a part of.';
END IF;

END//
DELIMITER ;

-- Dumping structure for procedure bequeathme.RemovePage
DELIMITER //
CREATE DEFINER=`root`@`localhost` PROCEDURE `RemovePage`(
	IN `_page` BIGINT UNSIGNED
)
    COMMENT 'Removes a page and sends out a "page deleted" notification to the pledgers'
BEGIN

SELECT @name := Name, @author := `User` FROM pages WHERE ID = _page FOR UPDATE;

INSERT INTO textcache (`Data`, `Aux`)
VALUES ((SELECT DisplayName FROM users WHERE ID = @author), @name);

SET @id = LAST_INSERT_ID();
INSERT INTO notifications (`User`, `Type`, `Data`)
SELECT `User`, 6, @id
FROM pledges
WHERE Page = _page;

DELETE FROM pages WHERE ID = _page;

END//
DELIMITER ;

-- Dumping structure for procedure bequeathme.RemovePledge
DELIMITER //
CREATE DEFINER=`root`@`localhost` PROCEDURE `RemovePledge`(
	IN `_user` BIGINT UNSIGNED,
	IN `_page` BIGINT UNSIGNED


)
    MODIFIES SQL DATA
    COMMENT 'Removes a pledge and notifies the creator'
BEGIN

DELETE FROM pledges WHERE `User` = _user AND Page = _page;

IF ROW_COUNT() > 0 THEN
	INSERT INTO notifications (`User`, Page, `Type`, `Data`)
	VALUES ((SELECT `User` FROM pages WHERE Page = _page), _page, 5, _user);
END IF;

END//
DELIMITER ;

-- Dumping structure for table bequeathme.rewards
CREATE TABLE IF NOT EXISTS `rewards` (
  `ID` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `Page` bigint(20) unsigned NOT NULL,
  `Order` tinyint(4) NOT NULL,
  `Name` varchar(256) NOT NULL DEFAULT '''''',
  `Description` varchar(1024) NOT NULL DEFAULT '''''',
  `Amount` decimal(10,8) unsigned NOT NULL DEFAULT 0.00000000,
  PRIMARY KEY (`ID`),
  KEY `INDEX_PAGE` (`Page`),
  CONSTRAINT `FK_REWARDS_PAGES` FOREIGN KEY (`Page`) REFERENCES `pages` (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Data exporting was unselected.
-- Dumping structure for procedure bequeathme.SendMessage
DELIMITER //
CREATE DEFINER=`root`@`localhost` PROCEDURE `SendMessage`(
	IN `_id` BIGINT UNSIGNED
)
    COMMENT 'Sends a message, but only if it has a valid recipient.'
BEGIN

DECLARE sender BIGINT UNSIGNED;
DECLARE recipient BIGINT UNSIGNED;
DECLARE title VARCHAR(256);
DECLARE content TEXT;
SELECT Sender, Recipient, Title, Content INTO sender, recipient, title, content FROM messages WHERE ID = _id FOR UPDATE;

IF sender IS NOT NULL AND recipient IS NOT NULL AND Title != '' AND content != '' THEN
	UPDATE messages SET Draft = 0 WHERE ID = _id;
ELSE
	SIGNAL SQLSTATE '45000'
	SET MESSAGE_TEXT = 'A message must have a sender, recipient, title, and content.';
END IF;

END//
DELIMITER ;

-- Dumping structure for table bequeathme.sources
CREATE TABLE IF NOT EXISTS `sources` (
  `ID` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `User` bigint(20) unsigned NOT NULL,
  `Paypal` varchar(64) DEFAULT NULL,
  `Stripe` varchar(48) DEFAULT NULL COMMENT 'A stripe payment source. The customer ID is stored on the user table itself',
  `Invalid` bit(1) NOT NULL DEFAULT b'0',
  `Trusted` bit(1) NOT NULL DEFAULT b'0',
  PRIMARY KEY (`ID`),
  KEY `FK_SOURCES_USERS` (`User`),
  CONSTRAINT `FK_SOURCES_USERS` FOREIGN KEY (`User`) REFERENCES `users` (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Represents any form of payment. All payment types start untrusted, which triggers manual processing of a single transaction outside of the normal monthly coalesce operation as soon as a transaction is available. If it succeeds, it''s marked as trusted. If it''s failed, it''s marked as invalid and cannot be used. If you have outstanding failed transactions, those MUST be paid off by any new payment method you add for it to be considered "trusted". ';

-- Data exporting was unselected.
-- Dumping structure for table bequeathme.textcache
CREATE TABLE IF NOT EXISTS `textcache` (
  `ID` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `Data` varchar(512) NOT NULL DEFAULT '''''',
  `Aux` varchar(512) NOT NULL DEFAULT '''''',
  PRIMARY KEY (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='This table is only used to cache text that will be needed in notifications about deleted pages or users whose information is no longer available.';

-- Data exporting was unselected.
-- Dumping structure for table bequeathme.transactions
CREATE TABLE IF NOT EXISTS `transactions` (
  `ID` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `User` bigint(20) unsigned NOT NULL,
  `Page` bigint(20) unsigned NOT NULL,
  `Charge` bigint(20) unsigned DEFAULT NULL,
  `Reward` bigint(20) unsigned DEFAULT NULL,
  `Source` bigint(20) unsigned DEFAULT NULL,
  `Amount` decimal(10,8) NOT NULL,
  `Timestamp` timestamp NOT NULL DEFAULT current_timestamp(),
  `Failed` bit(1) NOT NULL DEFAULT b'0' COMMENT 'Set to 1 if the last attempt to resolve this transaction failed. ',
  `Payment` bigint(20) unsigned DEFAULT NULL COMMENT 'Set to the last attempt to resolve this transaction, which may have failed.',
  PRIMARY KEY (`ID`),
  KEY `FK_TRANSACTIONS_USERS` (`User`),
  KEY `FK_TRANSACTIONS_PAGES` (`Page`),
  KEY `FK_TRANSACTIONS_REWARDS` (`Reward`),
  KEY `FK_TRANSACTIONS_SOURCES` (`Source`),
  KEY `FK_TRANSACTIONS_CHARGES` (`Charge`),
  KEY `FK_TRANSACTIONS_PAYMENTS` (`Payment`),
  CONSTRAINT `FK_TRANSACTIONS_CHARGES` FOREIGN KEY (`Charge`) REFERENCES `charges` (`ID`),
  CONSTRAINT `FK_TRANSACTIONS_PAGES` FOREIGN KEY (`Page`) REFERENCES `pages` (`ID`),
  CONSTRAINT `FK_TRANSACTIONS_PAYMENTS` FOREIGN KEY (`Payment`) REFERENCES `payments` (`ID`),
  CONSTRAINT `FK_TRANSACTIONS_REWARDS` FOREIGN KEY (`Reward`) REFERENCES `rewards` (`ID`),
  CONSTRAINT `FK_TRANSACTIONS_SOURCES` FOREIGN KEY (`Source`) REFERENCES `sources` (`ID`),
  CONSTRAINT `FK_TRANSACTIONS_USERS` FOREIGN KEY (`User`) REFERENCES `users` (`ID`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Data exporting was unselected.
-- Dumping structure for table bequeathme.users
CREATE TABLE IF NOT EXISTS `users` (
  `ID` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `Username` varchar(128) NOT NULL,
  `Password` varchar(512) DEFAULT NULL COMMENT 'Can be NULL if user only logs in via OAuth',
  `Email` varchar(128) NOT NULL,
  `DisplayName` varchar(256) NOT NULL DEFAULT '''''',
  `About` varchar(4096) NOT NULL DEFAULT '''''',
  `Privacy` tinyint(3) unsigned NOT NULL DEFAULT 0,
  `Joined` timestamp NOT NULL DEFAULT current_timestamp(),
  `Edited` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `LastRead` timestamp NOT NULL DEFAULT current_timestamp(),
  `Currency` smallint(5) unsigned NOT NULL DEFAULT 0,
  `Notify` bigint(20) unsigned NOT NULL DEFAULT 0,
  `Foreign` bit(1) NOT NULL DEFAULT b'0',
  `Individual` bit(1) NOT NULL DEFAULT b'1',
  `Banned` bit(1) NOT NULL DEFAULT b'0',
  `ShowSensitive` bit(1) NOT NULL DEFAULT b'0',
  `PayoutFailure` bit(1) NOT NULL DEFAULT b'0',
  `StripeCustomerID` varchar(48) DEFAULT NULL,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `UNIQUE_USERNAME` (`Username`),
  UNIQUE KEY `UNIQUE_EMAIL` (`Email`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Data exporting was unselected.
-- Dumping structure for procedure bequeathme.ValidateSource
DELIMITER //
CREATE DEFINER=`root`@`localhost` PROCEDURE `ValidateSource`(
	IN `_source` BIGINT UNSIGNED




)
    COMMENT 'Given a new, untrusted, valid payment source, creates a processing row based on invalid and/or recent transactions to force initial payment.'
BEGIN

SELECT @author := `User`, @trusted := Trusted, @invalid := Invalid 
FROM sources 
WHERE ID = _source;

IF @invalid = 0 AND @trusted = 0 THEN
	IF (SELECT COUNT(*) FROM transactions WHERE `User` = @author AND Failed = 1) > 0 THEN
		INSERT INTO payments (Source, Amount)
		SELECT Source, SUM(Amount)
		FROM transactions 
		WHERE `User` = @author AND Failed = 1
		GROUP BY Source;
	ELSE
		SELECT @id := ID, @source := Source, @amount := Amount 
		FROM transactions 
		WHERE `User` = @author AND Payment IS NULL LIMIT 1 FOR UPDATE;
		
		IF @id IS NOT NULL THEN
			INSERT INTO payments (Source, Amount)
			VALUES (@source, @amount);
			
			UPDATE transactions 
			SET Payment = LAST_INSERT_ID() 
			WHERE ID = @id;
		END IF;
	END IF;
END IF;

END//
DELIMITER ;

-- Dumping structure for trigger bequeathme.charges_before_delete
SET @OLDTMP_SQL_MODE=@@SQL_MODE, SQL_MODE='STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION';
DELIMITER //
CREATE TRIGGER `charges_before_delete` BEFORE DELETE ON `charges` FOR EACH ROW BEGIN

-- Any transactions that already succeeded must be refunded if the charge is deleted
INSERT INTO transactions (`User`, Page, Reward, Source, Amount)
SELECT `User`, Page, Reward, Source, -Amount
FROM transactions
WHERE charge = OLD.ID AND Failed = 0 AND `Payment` IS NOT NULL; 

DELETE FROM transactions WHERE Charge = OLD.ID;

UPDATE posts
SET Charge = NULL
WHERE Charge = OLD.ID;

END//
DELIMITER ;
SET SQL_MODE=@OLDTMP_SQL_MODE;

-- Dumping structure for trigger bequeathme.pages_before_delete
SET @OLDTMP_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION';
DELIMITER //
CREATE TRIGGER `pages_before_delete` BEFORE DELETE ON `pages` FOR EACH ROW BEGIN

DELETE FROM transactions WHERE Page = OLD.ID;
DELETE FROM notifications WHERE Page = OLD.ID;
DELETE FROM charges WHERE Page = OLD.ID;
DELETE FROM pledges WHERE Page = OLD.ID;
DELETE FROM posts WHERE Page = OLD.ID;
DELETE FROM goals WHERE Page = OLD.ID;
DELETE FROM rewards WHERE Page = OLD.ID;

END//
DELIMITER ;
SET SQL_MODE=@OLDTMP_SQL_MODE;

-- Dumping structure for trigger bequeathme.payments_before_delete
SET @OLDTMP_SQL_MODE=@@SQL_MODE, SQL_MODE='STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION';
DELIMITER //
CREATE TRIGGER `payments_before_delete` BEFORE DELETE ON `payments` FOR EACH ROW BEGIN

UPDATE transactions SET `Payment` = NULL WHERE `Payment` = OLD.ID;

END//
DELIMITER ;
SET SQL_MODE=@OLDTMP_SQL_MODE;

-- Dumping structure for trigger bequeathme.posts_before_delete
SET @OLDTMP_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION';
DELIMITER //
CREATE TRIGGER `posts_before_delete` BEFORE DELETE ON `posts` FOR EACH ROW BEGIN

UPDATE comments SET Reply = NULL WHERE Reply IN (SELECT ID FROM comments WHERE `User` = OLD.ID);
DELETE FROM comments WHERE `User` = OLD.ID;

DELETE FROM notifications WHERE Post = OLD.ID;

END//
DELIMITER ;
SET SQL_MODE=@OLDTMP_SQL_MODE;

-- Dumping structure for trigger bequeathme.rewards_before_delete
SET @OLDTMP_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION';
DELIMITER //
CREATE TRIGGER `rewards_before_delete` BEFORE DELETE ON `rewards` FOR EACH ROW BEGIN

UPDATE posts SET Locked = NULL WHERE Locked = OLD.ID;

SET @replace = (SELECT ID FROM rewards WHERE ID != OLD.ID AND Page = OLD.Page AND Amount <= OLD.Amount ORDER BY Amount DESC, `Order` ASC LIMIT 1);
UPDATE pledges SET Reward = @replace WHERE Reward = OLD.ID AND Page = OLD.Page;
UPDATE transactions SET Reward = @replace WHERE Reward = OLD.ID AND Page = OLD.Page;

END//
DELIMITER ;
SET SQL_MODE=@OLDTMP_SQL_MODE;

-- Dumping structure for trigger bequeathme.sources_before_delete
SET @OLDTMP_SQL_MODE=@@SQL_MODE, SQL_MODE='STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION';
DELIMITER //
CREATE TRIGGER `sources_before_delete` BEFORE DELETE ON `sources` FOR EACH ROW BEGIN

UPDATE payments SET Source = NULL WHERE `User` = OLD.`User`;

SET @target = (SELECT ID FROM sources WHERE `User` = OLD.`User` AND ID != OLD.ID AND Invalid = 0 LIMIT 1);

-- We update the transactions to either the new payment method, or NULL if none is available
UPDATE transactions SET Source = @target WHERE `User` = OLD.`User` AND Source = OLD.ID;

IF @target IS NULL THEN -- No other source method available, delete all pledges
DELETE FROM pledges WHERE `User` = OLD.`User` AND Source = OLD.ID;
ELSE -- Otherwise move any pledges on this source method to another source method
UPDATE pledges SET Source = @target WHERE `User` = OLD.`User` AND Source = OLD.ID;
END IF;

END//
DELIMITER ;
SET SQL_MODE=@OLDTMP_SQL_MODE;

-- Dumping structure for trigger bequeathme.users_before_delete
SET @OLDTMP_SQL_MODE=@@SQL_MODE, SQL_MODE='STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION';
DELIMITER //
CREATE TRIGGER `users_before_delete` BEFORE DELETE ON `users` FOR EACH ROW BEGIN

IF (SELECT COUNT(*) FROM transactions where `User` = OLD.ID AND (Failed IS NOT NULL OR Failed = 1)) > 0 THEN 
	SIGNAL SQLSTATE '45000'
	SET MESSAGE_TEXT = 'Cannot delete user with unpaid transactions';
END IF;
 
DELETE FROM transactions WHERE `User` = OLD.ID;
DELETE FROM notifications WHERE `User` = OLD.ID;

UPDATE payouts SET `User` = NULL WHERE `User` = OLD.ID;
UPDATE comments SET Reply = NULL WHERE Reply IN (SELECT ID FROM comments WHERE `User` = OLD.ID);
DELETE FROM comments WHERE `User` = OLD.ID;

UPDATE messages SET Sender = NULL WHERE Sender = OLD.ID;
UPDATE messages SET Recipient = NULL WHERE Recipient = OLD.ID;
DELETE FROM messages WHERE Sender IS NULL AND Recipient IS NULL;

DELETE FROM pledges WHERE `User` = OLD.ID;
DELETE FROM sources WHERE `User` = OLD.ID;
DELETE FROM pages WHERE `User` = OLD.ID;
DELETE FROM oauth WHERE `User` = OLD.ID;
DELETE FROM flags WHERE `User` = OLD.ID;
DELETE FROM blocked WHERE `User` = OLD.ID OR `Blocked` = OLD.ID;

END//
DELIMITER ;
SET SQL_MODE=@OLDTMP_SQL_MODE;

-- Dumping structure for view bequeathme.currentmonth
-- Removing temporary table and create final VIEW structure
DROP TABLE IF EXISTS `currentmonth`;
CREATE ALGORITHM=MERGE DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `currentmonth` AS SELECT * FROM transactions
WHERE `Timestamp` >= UNIX_TIMESTAMP(LAST_DAY(CURDATE()) + INTERVAL 1 DAY - INTERVAL 1 MONTH)
  AND `Timestamp` <  UNIX_TIMESTAMP(LAST_DAY(CURDATE()) + INTERVAL 1 DAY) ;

/*!40101 SET SQL_MODE=IFNULL(@OLD_SQL_MODE, '') */;
/*!40014 SET FOREIGN_KEY_CHECKS=IF(@OLD_FOREIGN_KEY_CHECKS IS NULL, 1, @OLD_FOREIGN_KEY_CHECKS) */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
